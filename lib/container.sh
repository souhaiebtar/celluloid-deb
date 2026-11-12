#!/usr/bin/env bash
# Containerised build driver.
#
# Every build happens inside a pristine container for the target suite.
# Nothing from the host leaks into the build except the source tree and the
# resulting .deb. This is what makes the packages trustworthy: they are built
# against the exact libraries the target Debian release ships.
#
# Supported engines: podman (preferred, rootless) and docker.
#
# Dependency caching
# ------------------
# Installing the build dependencies from scratch costs ~2.5 minutes per suite,
# which dominates the build for a small project like this. Instead, an image
# containing them is built once and reused:
#
#   base image + rendered Dockerfile  ->  image tag with a content hash
#
# The tag embeds a hash of the base image name, the dependency list and the
# Dockerfile template, so changing any of those produces a new tag and the
# stale image is simply not used. Nothing needs to be invalidated by hand.

if [[ -n "${_CELLULOID_CONTAINER_SH:-}" ]]; then return 0; fi
_CELLULOID_CONTAINER_SH=1

# Packages installed inside the build image. These are build-time only;
# runtime dependencies are derived automatically by ${shlibs:Depends}.
BUILD_DEPS=(
  appstream
  build-essential
  debhelper
  desktop-file-utils
  dpkg-dev
  fakeroot
  gettext
  libadwaita-1-dev
  libepoxy-dev
  libglib2.0-dev
  libgtk-4-dev
  libmpv-dev
  meson
  ninja-build
  pkgconf
)

# Local name for the cached build images. Kept under localhost/ so podman and
# docker both treat it as a locally built image rather than a registry pull.
BUILD_IMAGE_PREFIX="${BUILD_IMAGE_PREFIX:-localhost/celluloid-build}"

# detect_engine — print "podman" or "docker".
detect_engine() {
  if [[ -n "${CONTAINER_ENGINE:-}" ]]; then
    command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 \
      || die "CONTAINER_ENGINE=$CONTAINER_ENGINE not found"
    printf '%s' "$CONTAINER_ENGINE"
    return 0
  fi
  local c
  for c in podman docker; do
    if command -v "$c" >/dev/null 2>&1; then
      # verify the daemon/socket is actually reachable
      if "$c" info >/dev/null 2>&1; then
        printf '%s' "$c"
        return 0
      fi
      warn "$c is installed but not usable (daemon/socket unreachable)"
    fi
  done
  return 1
}

# _volume_opts <engine> — SELinux relabel suffix for bind mounts, else empty.
_volume_opts() {
  local engine=$1
  # SELinux hosts need :z relabelling; probing avoids errors elsewhere.
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    printf ':z'
  fi
}

# image_exists <engine> <image>
image_exists() {
  local engine=$1 image=$2
  # podman has `image exists`; docker spells it `image inspect`. Probe both so
  # this works on either engine without branching on the engine name.
  "$engine" image exists "$image" >/dev/null 2>&1 ||
    "$engine" image inspect "$image" >/dev/null 2>&1
}

# ensure_image <engine> <image>
ensure_image() {
  local engine=$1 image=$2
  image_exists "$engine" "$image" && return 0
  info "pulling image $image" >&2
  "$engine" pull "$image" >&2 || return 1
}

# render_dockerfile <base_image> <dest>
#
# Writes the build image recipe for a suite. Kept as a rendered file (rather
# than inline) so the result can be hashed for the cache tag.
render_dockerfile() {
  local base=$1 dest=$2
  local tmpl
  tmpl="$(dirname -- "${BASH_SOURCE[0]}")/../packaging/Dockerfile.build.in"
  [[ -f "$tmpl" ]] || { warn "missing $tmpl" >&2; return 1; }

  # Join the dependency list with line continuations so the Dockerfile stays
  # readable and diffs cleanly.
  local deps="" d sep=""
  for d in "${BUILD_DEPS[@]}"; do
    deps+="${sep}${d}"
    sep=$' \\\n      '
  done

  # Escape sed metacharacters in the substitution values: an image name or a
  # dependency containing / & or \ would otherwise corrupt the output.
  # Newlines in the dependency list are emitted as literal \n + newline, which
  # sed's replacement cannot express portably, so the template is rendered in
  # bash instead.
  local line out=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      *'@BASE_IMAGE@'*) line=${line//@BASE_IMAGE@/$base} ;;
    esac
    case "$line" in
      *'@BUILD_DEPS@'*) line=${line//@BUILD_DEPS@/$deps} ;;
    esac
    out+="$line"$'\n'
  done < "$tmpl"

  printf '%s' "$out" > "$dest"
}

# build_image_ref <suite> <base_image>
#
# Prints the local image reference for a suite. The hash makes the tag a
# function of everything that affects the image contents, so a changed
# dependency list or base image yields a different tag automatically.
build_image_ref() {
  local suite=$1 base=$2 rendered hash
  rendered=$(mktemp "${TMPDIR:-/tmp}/celluloid-dockerfile.XXXXXX") || return 1
  render_dockerfile "$base" "$rendered" || { rm -f "$rendered"; return 1; }
  hash=$(sha256sum "$rendered" | cut -c1-12)
  rm -f "$rendered"
  printf '%s:%s-%s' "$BUILD_IMAGE_PREFIX" "$suite" "$hash"
}

# ensure_build_image <engine> <suite> <base_image>
#
# Builds the dependency image if it is not already present. Prints the image
# reference to use on stdout; diagnostics go to stderr.
#
# Returns non-zero if the image could not be built, which the caller treats as
# a cue to fall back to installing dependencies at build time.
ensure_build_image() {
  local engine=$1 suite=$2 base=$3
  local ref ctx logfile

  ref=$(build_image_ref "$suite" "$base") || return 1

  if (( REBUILD_IMAGE )); then
    step "rebuilding build image $ref (requested)" >&2
    "$engine" rmi -f "$ref" >/dev/null 2>&1 || true
  fi

  if image_exists "$engine" "$ref"; then
    ok "using cached build image $ref" >&2
    printf '%s' "$ref"
    return 0
  fi

  # Cache miss: build it. A failure here is not fatal to the whole run, since
  # the caller can still install dependencies inside a plain base container.
  step "building dependency image $ref (one-time, cached afterwards)" >&2
  ctx=$(mktemp -d "${TMPDIR:-/tmp}/celluloid-build-ctx.XXXXXX") || return 1
  render_dockerfile "$base" "$ctx/Dockerfile" || { rm -rf "$ctx"; return 1; }

  logfile="${WORK_DIR:-.}/image-$suite.log"
  mkdir -p "$(dirname "$logfile")"
  : > "$logfile"

  if verbose; then
    "$engine" build -t "$ref" -f "$ctx/Dockerfile" "$ctx" 2>&1 | tee -a "$logfile"
  else
    "$engine" build -t "$ref" -f "$ctx/Dockerfile" "$ctx" >>"$logfile" 2>&1
  fi
  local rc=$?
  rm -rf "$ctx"

  if (( rc != 0 )); then
    warn "could not build dependency image; see $logfile" >&2
    return 1
  fi

  ok "built dependency image $ref" >&2
  printf '%s' "$ref"
}

# build_in_container <engine> <image> <workroot> <outdir> <logfile> <deps_present:0|1>
#
# Runs dpkg-buildpackage inside the container. The source tree is already laid
# out as <workroot>/celluloid-<version> with a generated debian/ directory.
#
# deps_present=1 means the image already contains the build dependencies, so
# the apt steps are skipped entirely. That is the whole point of the cached
# image: it removes the dominant cost of a build.
build_in_container() {
  local engine=$1 image=$2 workroot=$3 outdir=$4 logfile=$5 deps_present=${6:-0}
  local opts vol_work vol_out

  opts=$(_volume_opts "$engine")
  vol_work="$workroot:/workbuild$opts"
  vol_out="$outdir:/outbuild$opts"

  # The inner script is intentionally explicit: no reliance on host state.
  # - dpkg-buildpackage runs as an unprivileged user inside the container
  # - `-b` builds a binary-only package, everything we need
  # - `-uc -us` skips signing; we sign nothing locally
  # - `--no-pre-clean` keeps our generated debian/ tree intact
  # shellcheck disable=SC2016
  local inner='
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
# Debug symbols are off by default: the dbgsym package is large, and nobody
# consuming a locally built release package needs it. Set WITH_DBGSYM=1 to
# build it anyway. dh_strip honours noautodbgsym from DEB_BUILD_OPTIONS.
if [ "${WITH_DBGSYM:-0}" != "1" ]; then
  export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }noautodbgsym"
fi

if [ "${DEPS_PRESENT:-0}" = "1" ]; then
  echo "### build dependencies already present in image"
else
  echo "### apt-get update"
  apt-get update -qq || exit 1
  echo "### installing build dependencies"
  apt-get install -y -qq --no-install-recommends '"${BUILD_DEPS[*]}"' || exit 1
fi

echo "### building"
# The stage directory holds exactly one celluloid-<version> tree. Find it
# explicitly rather than relying on glob expansion, which breaks if a stale
# tree from an earlier attempt is present.
src=$(find /workbuild -mindepth 1 -maxdepth 1 -type d -name 'celluloid-*' | head -1)
if [ -z "$src" ]; then
  echo "no source tree found under /workbuild" >&2
  exit 1
fi
cd "$src" || exit 1
dpkg-buildpackage -b -uc -us --no-pre-clean -j"$(nproc)" 2>&1 || exit 1

echo "### collecting artifacts"
shopt -s nullglob
found=0
# dpkg-buildpackage writes one level above the source tree, i.e. /workbuild.
for f in /workbuild/*.deb; do
  cp -v "$f" /outbuild/ || exit 1
  found=1
done
if [ "$found" -eq 0 ]; then
  echo "no .deb produced" >&2
  exit 1
fi
echo "### done"
'

  # Start each build with a fresh log; appending across runs makes failures
  # impossible to attribute to the attempt that actually caused them.
  : > "$logfile"

  local -a run_args=(
    run --rm
    -v "$vol_work"
    -v "$vol_out"
    -e "HOST_UID=$(id -u)"
    -e "HOST_GID=$(id -g)"
    -e "WITH_DBGSYM=${WITH_DBGSYM:-0}"
    -e "DEPS_PRESENT=$deps_present"
    "$image" bash -c "$inner"
  )

  if verbose; then
    "$engine" "${run_args[@]}" 2>&1 | tee -a "$logfile"
    # Return the container's status, not tee's: inside a pipeline $? is the
    # last command's, which would report success on a failed build.
    return "${PIPESTATUS[0]}"
  fi

  "$engine" "${run_args[@]}" >>"$logfile" 2>&1
}

# fix_ownership <dir> — container builds may leave root-owned files in bind
# mounts on engines that map the root user through. Take them back so the tree
# stays usable and can be cleaned up.
fix_ownership() {
  local dir=$1
  [[ -d "$dir" ]] || return 0
  # only attempt when something is actually owned by another uid
  if find "$dir" ! -user "$(id -u)" -print -quit 2>/dev/null | grep -q .; then
    if command -v podman >/dev/null 2>&1; then
      # Inside `podman unshare` the host uid is mapped to root, so chown to 0:0
      # is what returns ownership to us on the host. Using "id -u" here would
      # chown to a subuid and make things worse.
      podman unshare chown -R 0:0 "$dir" 2>/dev/null && return 0
    fi
    warn "some files in $dir are not owned by you; you may need sudo to remove them"
  fi
}
