#!/usr/bin/env bash
# Containerised build driver.
#
# Every build happens inside a pristine container image for the target suite.
# Nothing from the host leaks into the build except the source tree and the
# resulting .deb. This is what makes the packages trustworthy: they are built
# against the exact libraries the target Debian release ships.
#
# Supported engines: podman (preferred, rootless) and docker.

if [[ -n "${_CELLULOID_CONTAINER_SH:-}" ]]; then return 0; fi
_CELLULOID_CONTAINER_SH=1

# Packages installed inside the build container. These are build-time only;
# runtime dependencies are derived automatically by ${shlibs:Depends}.
BUILD_DEPS=(
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
  appstream
)

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

# ensure_image <engine> <image>
ensure_image() {
  local engine=$1 image=$2
  # podman has `image exists`; docker spells it `image inspect`. Probe both so
  # the function works on either engine without branching on the engine name.
  if "$engine" image exists "$image" >/dev/null 2>&1 ||
     "$engine" image inspect "$image" >/dev/null 2>&1; then
    return 0
  fi
  info "pulling image $image" >&2
  "$engine" pull "$image" >&2 || return 1
}

# build_in_container <engine> <image> <sourcedir> <outdir> <logfile>
#
# Runs dpkg-buildpackage inside the container. The source tree is already laid
# out as <sourcedir>/celluloid-<version> with a generated debian/ directory.
build_in_container() {
  local engine=$1 image=$2 workroot=$3 outdir=$4 logfile=$5
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

echo "### apt-get update"
apt-get update -qq || exit 1

echo "### installing build dependencies"
apt-get install -y -qq --no-install-recommends '"${BUILD_DEPS[*]}"' || exit 1

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

  if verbose; then
    "$engine" run --rm \
      -v "$vol_work" \
      -v "$vol_out" \
      -e "HOST_UID=$(id -u)" \
      -e "HOST_GID=$(id -g)" \
      -e "WITH_DBGSYM=${WITH_DBGSYM:-0}" \
      "$image" bash -c "$inner" 2>&1 | tee -a "$logfile"
    # Return the container's status, not tee's: inside a pipeline $? is the
    # last command's, which would report success on a failed build.
    return "${PIPESTATUS[0]}"
  fi

  "$engine" run --rm \
    -v "$vol_work" \
    -v "$vol_out" \
    -e "HOST_UID=$(id -u)" \
    -e "HOST_GID=$(id -g)" \
    -e "WITH_DBGSYM=${WITH_DBGSYM:-0}" \
    "$image" bash -c "$inner" >>"$logfile" 2>&1
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
