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
  desktop-file-utils iso-codes
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

# build_in_container <engine> <image> <workroot> <outdir> <logfile> <deps_present:0|1> [backport_dir]
#
# Runs dpkg-buildpackage inside the container. The source tree is already laid
# out as <workroot>/celluloid-<version> with a generated debian/ directory.
#
# deps_present=1 means the image already contains the build dependencies, so
# the apt steps are skipped entirely. That is the whole point of the cached
# image: it removes the dominant cost of a build.
#
# backport_dir, when given, holds the private-prefix GTK/libadwaita packages.
# They are installed inside the container so Celluloid 0.30 builds against GTK
# 4.20 instead of the suite's own GTK, and the result is linked with an rpath so
# it resolves them at runtime.
build_in_container() {
  local engine=$1 image=$2 workroot=$3 outdir=$4 logfile=$5 deps_present=${6:-0}
  local backport_dir=${7:-}
  local opts vol_work vol_out vol_backports=""

  opts=$(_volume_opts "$engine")
  vol_work="$workroot:/workbuild$opts"
  vol_out="$outdir:/outbuild$opts"
  if [[ -n "$backport_dir" ]]; then
    vol_backports="$backport_dir:/backports:ro$opts"
  fi

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
# Install the private-prefix GTK/libadwaita backports when provided. They live
# under /opt, so nothing here replaces a Debian-packaged library.
if [ "${USE_BACKPORTS:-0}" = "1" ]; then
  echo "### installing GTK/libadwaita backports"
  dpkg -i /backports/*.deb || exit 1
  export PKG_CONFIG_PATH=/opt/gtk420/lib/x86_64-linux-gnu/pkgconfig
  echo "gtk4:       $(pkg-config --modversion gtk4)"
  echo "libadwaita: $(pkg-config --modversion libadwaita-1)"
fi

# The stage directory holds exactly one celluloid-<version> tree. Find it
# explicitly rather than relying on glob expansion, which breaks if a stale
# tree from an earlier attempt is present.
src=$(find /workbuild -mindepth 1 -maxdepth 1 -type d -name 'celluloid-*' | head -1)
if [ -z "$src" ]; then
  echo "no source tree found under /workbuild" >&2
  exit 1
fi
cd "$src" || exit 1

# meson reads the link arguments from the generated debian/rules via
# DH_OPTIONS-independent env: keeping it here means the packaging template does
# not have to know whether backports are in play.
if [ "${USE_BACKPORTS:-0}" = "1" ]; then
  export DEB_LDFLAGS_MAINT_APPEND="-Wl,-rpath,/opt/gtk420/lib/x86_64-linux-gnu"
  # Tells debian/rules to add the private prefix to the shlibdeps search path.
  export USE_BACKPORTS=1
fi
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
    -e "USE_BACKPORTS=${backport_dir:+1}"
  )
  if [[ -n "$vol_backports" ]]; then
    run_args+=(-v "$vol_backports")
  fi
  run_args+=("$image" bash -c "$inner")

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

# ===========================================================================
# Backport builds
#
# These need a chain: wayland 1.24 -> GTK 4.20 -> libadwaita 1.8. Each stage
# requires the previous one to be installed into a prefix, so the build runs as
# one container per package with the prefix carried in a volume.
# ===========================================================================

# Build dependencies for wayland 1.24.
WAYLAND_BUILD_DEPS=(build-essential meson ninja-build pkgconf debhelper dpkg-dev libffi-dev libexpat1-dev libxml2-dev)

# Build dependencies for GTK 4.20. wayland-protocols comes from trixie (1.44 is
# new enough); wayland itself is built first.
GTK_BUILD_DEPS=(
  build-essential meson ninja-build pkgconf gettext debhelper dpkg-dev fakeroot
  libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev
  libgraphene-1.0-dev libepoxy-dev libxkbcommon-dev libdrm-dev
  libffi-dev libexpat1-dev libxml2-dev
  libx11-dev libxi-dev libxext-dev libxrandr-dev libxcursor-dev
  libxdamage-dev libxfixes-dev libxinerama-dev
  libfribidi-dev libpng-dev libtiff-dev libjpeg-dev libharfbuzz-dev
  librsvg2-dev libfontconfig-dev libcolord-dev libcups2-dev
  libsysprof-capture-4-dev wayland-protocols python3-jinja2 iso-codes \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev
)

# Build dependencies for libadwaita 1.8. It needs a GTK dev environment, which
# the private prefix provides once GTK is installed there.
ADW_BUILD_DEPS=(
  build-essential meson ninja-build pkgconf gettext debhelper dpkg-dev fakeroot
  libglib2.0-dev libpango1.0-dev libcairo2-dev libgdk-pixbuf-2.0-dev
  libgraphene-1.0-dev libepoxy-dev libxkbcommon-dev libdrm-dev
  libffi-dev libexpat1-dev libxml2-dev
  libx11-dev libxi-dev libxext-dev libxrandr-dev libxcursor-dev
  libxdamage-dev libxfixes-dev libxinerama-dev
  libfribidi-dev libpng-dev libtiff-dev libjpeg-dev libharfbuzz-dev
  librsvg2-dev libfontconfig-dev libcolord-dev libcups2-dev
  libsysprof-capture-4-dev wayland-protocols python3-jinja2
  libappstream-dev sassc
)

# _pkgconfig_path <prefix>... — colon-joined pkgconfig search path for prefixes.
_pkgconfig_path() {
  local out="" p
  for p in "$@"; do
    out+="${out:+:}$p/lib/x86_64-linux-gnu/pkgconfig:$p/lib/pkgconfig:$p/share/pkgconfig"
  done
  printf '%s' "$out"
}

# _run_engine <engine> <logfile> <script> <image> [extra args...]
# Shared plumbing for the backport containers: fresh log, verbose handling,
# correct exit status through tee.
_run_engine() {
  local engine=$1 logfile=$2 script=$3 image=$4
  shift 4

  : > "$logfile"
  if verbose; then
    "$engine" run --rm "$@" "$image" bash -c "$script" 2>&1 | tee -a "$logfile"
    return "${PIPESTATUS[0]}"
  fi
  "$engine" run --rm "$@" "$image" bash -c "$script" >>"$logfile" 2>&1
}

# build_gtk_in_container <stage_dir> <outdir> <logfile> <wayland_tarball>
#
# Builds wayland 1.24 into a private prefix, then GTK 4.20 against it, then
# packages GTK. Wayland is staged inside the image and discarded with it: GTK
# needs it only to compile its Wayland backend.
build_gtk_in_container() {
  local stage=$1 outdir=$2 logfile=$3 wayland_tar=$4
  local engine opts vol_stage vol_out vol_wl
  local wayland_prefix="${WAYLAND_PREFIX:-/opt/wl124}"
  local gtk_prefix="${GTK_PREFIX:-/opt/gtk420}"
  local pkgconfig_path
  pkgconfig_path=$(_pkgconfig_path "$wayland_prefix" "$gtk_prefix")

  engine=$(detect_engine) || die "no usable container engine"
  [[ -s "$wayland_tar" ]] || { warn "missing wayland tarball: $wayland_tar" >&2; return 1; }
  opts=$(_volume_opts "$engine")
  # Mount the *parent* of the staged tree, so /workbuild holds gtk-<version>/
  # rather than being the tree itself.
  local stage_parent
  stage_parent=$(dirname "$stage")
  vol_stage="$stage_parent:/workbuild$opts"
  vol_out="$outdir:/outbuild$opts"
  # Mount just the wayland tarball, not its directory: the cache also holds
  # other sources and a broad glob inside the container would pick them up.
  vol_wl="$wayland_tar:/wlsrc/$(basename "$wayland_tar"):ro$opts"

  # shellcheck disable=SC2016
  local inner='
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }noautodbgsym"

echo "### installing build dependencies"
apt-get update -qq || exit 1
apt-get install -y -qq --no-install-recommends '"${GTK_BUILD_DEPS[*]}"' || exit 1

echo "### building wayland (build-time only)"
mkdir -p /wl-build && cd /wl-build || exit 1
# Only wayland: the mount is a single tarball at a known path.
for a in /wlsrc/wayland-*.tar.xz; do tar -xf "$a" || exit 1; done
cd wayland-* || exit 1
meson setup _b --buildtype=plain --prefix='"$wayland_prefix"' \
  -Ddocumentation=false -Dtests=false >/dev/null || exit 1
ninja -C _b >/dev/null && ninja -C _b install >/dev/null || exit 1
echo "wayland installed to '"$wayland_prefix"'"

export PKG_CONFIG_PATH='"$pkgconfig_path"'

echo "### building GTK"
src=$(find /workbuild -mindepth 1 -maxdepth 1 -type d -name "gtk-*" | head -1)
[ -n "$src" ] || { echo "no GTK source tree" >&2; exit 1; }
cd "$src" || exit 1
dpkg-buildpackage -b -uc -us --no-pre-clean -j"$(nproc)" 2>&1 || exit 1

echo "### collecting"
shopt -s nullglob
found=0
for f in /workbuild/*.deb; do cp -v "$f" /outbuild/ || exit 1; found=1; done
[ "$found" -eq 1 ] || { echo "no .deb produced" >&2; exit 1; }
echo "### done"
'

  _run_engine "$engine" "$logfile" "$inner" "docker.io/library/debian:13" \
    -v "$vol_stage" -v "$vol_out" -v "$vol_wl"
}

# build_adw_in_container <stage_dir> <outdir> <logfile>
#
# Builds libadwaita against the GTK already installed in the prefix. The GTK
# .deb is unpacked into the container first so the dev files are available
# without needing the package installed.
build_adw_in_container() {
  local stage=$1 outdir=$2 logfile=$3
  local engine opts vol_stage vol_out vol_gtk gtk_deb
  local gtk_prefix="${GTK_PREFIX:-/opt/gtk420}"
  local wayland_prefix="${WAYLAND_PREFIX:-/opt/wl124}"
  local pkgconfig_path
  # Resolved on the host: the container has no access to this script's helpers.
  pkgconfig_path=$(_pkgconfig_path "$gtk_prefix" "$wayland_prefix")

  engine=$(detect_engine) || die "no usable container engine"
  opts=$(_volume_opts "$engine")
  local stage_parent
  stage_parent=$(dirname "$stage")
  vol_stage="$stage_parent:/workbuild$opts"
  vol_out="$outdir:/outbuild$opts"

  # The GTK packages built by the previous stage.
  shopt -s nullglob
  local gtk_glob=("$outdir"/libgtk-4-1-backport_*.deb)
  shopt -u nullglob
  (( ${#gtk_glob[@]} )) || { warn "GTK .deb missing; build GTK first" >&2; return 1; }
  gtk_deb=${gtk_glob[0]}

  local gtkdir
  gtkdir=$(dirname "$gtk_deb")
  vol_gtk="$gtkdir:/gtkdeb:ro$opts"

  # shellcheck disable=SC2016
  local inner='
set -o pipefail
export DEBIAN_FRONTEND=noninteractive
export DEB_BUILD_OPTIONS="${DEB_BUILD_OPTIONS:+$DEB_BUILD_OPTIONS }noautodbgsym"

echo "### installing build dependencies"
apt-get update -qq || exit 1
apt-get install -y -qq --no-install-recommends '"${ADW_BUILD_DEPS[*]}"' || exit 1

# Unpack the backported GTK into the private prefix so pkg-config finds a real
# GTK dev environment. No system file is touched.
echo "### unpacking backported GTK into '"$gtk_prefix"'"
for deb in /gtkdeb/*.deb; do dpkg-deb -x "$deb" / ; done
export PKG_CONFIG_PATH='"$pkgconfig_path"'
echo "gtk4 seen: $(pkg-config --modversion gtk4)"

src=$(find /workbuild -mindepth 1 -maxdepth 1 -type d -name "libadwaita-*" | head -1)
[ -n "$src" ] || { echo "no libadwaita source tree" >&2; exit 1; }
cd "$src" || exit 1
dpkg-buildpackage -b -uc -us --no-pre-clean -j"$(nproc)" 2>&1 || exit 1

echo "### collecting"
shopt -s nullglob
found=0
for f in /workbuild/*.deb; do cp -v "$f" /outbuild/ || exit 1; found=1; done
[ "$found" -eq 1 ] || { echo "no .deb produced" >&2; exit 1; }
echo "### done"
'

  _run_engine "$engine" "$logfile" "$inner" "docker.io/library/debian:13" \
    -v "$vol_stage" -v "$vol_out" -v "$vol_gtk"
}
