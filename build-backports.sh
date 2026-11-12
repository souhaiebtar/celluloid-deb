#!/usr/bin/env bash
#
# build-backports.sh — build the library backports Debian 13 needs for
# Celluloid 0.30, and (optionally) Celluloid itself against them.
#
# Produces private-prefix .deb files in dist/backports/:
#   libgtk-4-1-backport       GTK 4.20      -> /opt/gtk420
#   libadwaita-1-0-backport   libadwaita 1.8 -> /opt/gtk420
#
# wayland 1.24 is built inside the GTK build container but is NOT packaged: it is
# a build-time dependency only. See docs/backport-design.md.
#
# Why a separate script: these are not application packages. They exist only
# because Debian 13 ships GTK 4.18, and Celluloid 0.30 needs GTK >= 4.19.4 via
# libadwaita 1.8.
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly BACKPORTS_FILE="$SCRIPT_DIR/backports.toml"
readonly TEMPLATE_DIR="$SCRIPT_DIR/packaging/backport"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/container.sh
source "$SCRIPT_DIR/lib/container.sh"

VERBOSE=0
LIST_ONLY=0
REBUILD=0
OUTPUT_DIR="$SCRIPT_DIR/dist/backports"
WORK_DIR="$SCRIPT_DIR/build/backports"

MAINTAINER_NAME="${DEBFULLNAME:-Celluloid Local Build}"
MAINTAINER_EMAIL="${DEBEMAIL:-celluloid@localhost.localdomain}"
MAINTAINER="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

# Where the private libraries live, shared by the packages.
GTK_PREFIX="/opt/gtk420"
WAYLAND_PREFIX="/opt/wl124"
DEBIAN_REV="1~trixie"

usage() {
  cat <<'EOF'
Build the library backports Debian 13 needs for Celluloid 0.30.

USAGE
  ./build-backports.sh [options]

Produces, in ./dist/backports:
  libgtk-4-1-backport_4.20.4-1~trixie_amd64.deb
  libadwaita-1-0-backport_1.8.8-1~trixie_amd64.deb

Installed into /opt/gtk420 so no Debian-packaged library is replaced.

OPTIONS
      --list        Show what would be built and exit
      --rebuild     Re-download sources instead of using cached tarballs
  -o, --output DIR  Write .deb files here (default: ./dist/backports)
  -w, --work DIR    Scratch directory (default: ./build/backports)
      --verbose     Stream build logs
  -h, --help        Show this help

NOTE
  wayland 1.24 is built inside the GTK image but not packaged: GTK 4.20 needs it
  to compile, while the runtime binds the system wayland. See
  docs/backport-design.md.
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
         --list)     LIST_ONLY=1; shift ;;
         --rebuild)  REBUILD=1; shift ;;
      -o|--output)   OUTPUT_DIR="${2:?--output needs a value}"; shift 2 ;;
      -w|--work)     WORK_DIR="${2:?--work needs a value}"; shift 2 ;;
         --verbose)  VERBOSE=1; shift ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "unknown argument: $1 (try --help)" ;;
    esac
  done
}

# ------------------------------------------------------------------ config ---
# TOML here is simple enough that a tiny reader is clearer than a dependency,
# but tomllib ships with python3 >= 3.11 so use it and stay honest about types.
cfg() {
  python3 - "$BACKPORTS_FILE" "$1" "$2" <<'PY'
import sys
import tomllib

path, section, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
if section not in data:
    sys.exit(f"no section {section!r} in {path}")
val = data[section].get(key)
if val is None:
    sys.exit(f"section {section!r} has no key {key!r}")
if isinstance(val, bool):
    print("1" if val else "0")
elif isinstance(val, list):
    print(" ".join(str(v) for v in val))
else:
    print(val)
PY
}

# Artifact versions, read from the same file the build uses so the two cannot
# drift apart.
gtk_version()      { cfg gtk version; }
gtk_url()          { cfg gtk url; }
adw_version()      { cfg libadwaita version; }
adw_url()          { cfg libadwaita url; }
wayland_version()  { cfg wayland version; }
wayland_url()      { cfg wayland url; }

show_plan() {
  info "backport plan"
  printf '  %-34s %-10s %s\n' "PACKAGE" "VERSION" "PREFIX" >&2
  printf '  %-34s %-10s %s\n' "libgtk-4-1-backport"     "$(gtk_version)" "$GTK_PREFIX" >&2
  printf '  %-34s %-10s %s\n' "libadwaita-1-0-backport" "$(adw_version)" "$GTK_PREFIX" >&2
  printf '\n  wayland %s: build-time only, not packaged\n' "$(wayland_version)" >&2
}

# ------------------------------------------------------------------ sources ---
# fetch <name> <url> <cache_dir> — print the path to the extracted source tree.
fetch_source() {
  local name=$1 url=$2 cache=$3 tarball unpack
  mkdir -p "$cache"
  tarball="$cache/$(basename "${url%%\?*}")"

  if (( REBUILD )) || [[ ! -s "$tarball" ]]; then
    step "downloading $(basename "$tarball")"
    local opts=(-fL --retry 3 --max-time 900)
    if verbose; then opts+=(--progress-bar); else opts+=(-sS); fi
    curl "${opts[@]}" -o "$tarball.part" "$url" || { rm -f "$tarball.part"; return 1; }
    mv -f "$tarball.part" "$tarball"
  else
    step "using cached $(basename "$tarball")"
  fi

  unpack="$cache/unpack-$name"
  rm -rf "$unpack"; mkdir -p "$unpack"
  tar -xf "$tarball" -C "$unpack" || return 1

  # the release archives hold exactly one top-level directory
  local top
  top=$(find "$unpack" -mindepth 1 -maxdepth 1 -type d | head -1)
  [[ -n "$top" ]] || { warn "no source directory in $tarball" >&2; return 1; }
  printf '%s' "$top"
}

# ---------------------------------------------------------------- packaging ---
# generate_debian <srcdir> <name> <version> <prefix> <package> [meson_args...]
generate_debian() {
  local srcdir=$1 name=$2 version=$3 prefix=$4 package=$5
  shift 5
  local meson_args="$*"
  local d="$srcdir/debian"

  rm -rf "$d"
  mkdir -p "$d/source"

  # libadwaita links against the backported GTK, which lives under a private
  # prefix and so cannot be discovered by shlibdeps. The dependency is declared
  # here instead; GTK itself needs nothing extra.
  local extra_depends="" shlibdeps_extra=""
  if [[ "$name" == "libadwaita" ]]; then
    extra_depends="         libgtk-4-1-backport,"
    # GTK is a separate backport package, unpacked at $prefix inside the build
    # container. -l lets shlibdeps resolve libgtk-4.so.1 from there.
    shlibdeps_extra="-l${prefix}/lib/x86_64-linux-gnu"
  fi

  sed -e "s|@NAME@|${name}|g" \
      -e "s|@PACKAGE@|${package}|g" \
      -e "s|@VERSION@|${version}|g" \
      -e "s|@PREFIX@|${prefix}|g" \
      -e "s|@EXTRA_DEPENDS@|${extra_depends}|g" \
      -e "s|@MAINTAINER@|${MAINTAINER}|g" \
      "$TEMPLATE_DIR/control" > "$d/control"

  # An empty @EXTRA_DEPENDS@ leaves a continuation line consisting only of
  # whitespace. That one line is a problem (it would split Depends:), so remove
  # whitespace-only lines that are immediately followed by "Description:".
  sed -i '/^[[:space:]]*$/{N;/^[[:space:]]*\nDescription:/s/^[[:space:]]*\n//}' "$d/control"

  sed -e "s|@PREFIX@|${prefix}|g" \
      -e "s|@PACKAGE@|${package}|g" \
      -e "s|@MESON_ARGS@|${meson_args}|g" \
      -e "s|@SHLIBDEPS_EXTRA@|${shlibdeps_extra}|g" \
      "$TEMPLATE_DIR/rules" > "$d/rules"
  chmod 0755 "$d/rules"

  sed -e "s|@NAME@|${name}|g" \
      -e "s|@VERSION@|${version}|g" \
      -e "s|@MAINTAINER@|${MAINTAINER}|g" \
      "$TEMPLATE_DIR/copyright" > "$d/copyright"
  chmod 0644 "$d/copyright" "$d/control"

  # libadwaita links against the backported GTK, which is a separate package and
  # therefore has no shlibs database entry. debian/shlibs.local supplies the
  # dependency mapping for it; without this dpkg-shlibdeps aborts with
  # "no dependency information found".
  if [[ "$name" == "libadwaita" ]]; then
    cat > "$d/shlibs.local" <<'SL'
libgtk-4 1 libgtk-4-1-backport (>= 4.20)
SL
    chmod 0644 "$d/shlibs.local"
  fi

  cp "$TEMPLATE_DIR/source/format" "$d/source/format"
  chmod 0644 "$d/source/format"

  cat > "$d/changelog" <<EOF
${name}-backport (${version}-${DEBIAN_REV}) trixie; urgency=medium

  * Backport ${name} ${version} into ${prefix} for Celluloid 0.30 on Debian 13.
  * Private prefix: no Debian-packaged library is replaced.

 -- ${MAINTAINER}  $(date -R)
EOF
  chmod 0644 "$d/changelog"
}

# -------------------------------------------------------------------- build ---
# build_gtk — GTK 4.20 into $GTK_PREFIX, with wayland 1.24 built alongside it.
build_gtk() {
  local version url src stage log rc
  version=$(gtk_version); url=$(gtk_url)
  log="$WORK_DIR/gtk.log"
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

  info "[gtk] ${version} -> ${GTK_PREFIX}"

  src=$(fetch_source gtk "$url" "$WORK_DIR/src") || die "[gtk] fetch failed"

  # stage as gtk-<version> so dpkg-buildpackage sees the expected tree shape
  stage="$WORK_DIR/stage/gtk-backport-${version}"
  rm -rf "$WORK_DIR/stage"; mkdir -p "$(dirname "$stage")"
  cp -a "$src" "$stage"

  # shellcheck disable=SC2046
  generate_debian "$stage" gtk "$version" "$GTK_PREFIX" libgtk-4-1-backport $(cfg gtk meson_args)

  # wayland is fetched here so the container only has to build it.
  local wl_cache="$WORK_DIR/src" wl_url wl_tar
  wl_url=$(wayland_url)
  mkdir -p "$wl_cache"
  wl_tar="$wl_cache/$(basename "${wl_url%%\?*}")"
  if (( REBUILD )) || [[ ! -s "$wl_tar" ]]; then
    step "downloading $(basename "$wl_tar")"
    local opts=(-fL --retry 3 --max-time 900)
    if verbose; then opts+=(--progress-bar); else opts+=(-sS); fi
    curl "${opts[@]}" -o "$wl_tar.part" "$wl_url" \
      || { rm -f "$wl_tar.part"; return 1; }
    mv -f "$wl_tar.part" "$wl_tar"
  fi

  step "building in debian:13 (builds a private wayland first)"
  build_gtk_in_container "$stage" "$OUTPUT_DIR" "$log" "$wl_tar" || rc=$?

  if (( ${rc:-0} != 0 )); then
    warn "[gtk] build failed; see $log"
    return 1
  fi
  ok "[gtk] built $(basename "$(ls "$OUTPUT_DIR"/libgtk-4-1-backport_*.deb 2>/dev/null | head -1)")"
}

# build_libadwaita — libadwaita 1.8 into $GTK_PREFIX, against the backported GTK.
build_libadwaita() {
  local version url src stage log rc
  version=$(adw_version); url=$(adw_url)
  log="$WORK_DIR/libadwaita.log"
  mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

  info "[libadwaita] ${version} -> ${GTK_PREFIX}"

  src=$(fetch_source libadwaita "$url" "$WORK_DIR/src") || die "[libadwaita] fetch failed"

  stage="$WORK_DIR/stage/libadwaita-backport-${version}"
  rm -rf "$WORK_DIR/stage"; mkdir -p "$(dirname "$stage")"
  cp -a "$src" "$stage"

  # shellcheck disable=SC2046
  generate_debian "$stage" libadwaita "$version" "$GTK_PREFIX" libadwaita-1-0-backport $(cfg libadwaita meson_args)

  step "building in debian:13 (against the backported GTK)"
  build_adw_in_container "$stage" "$OUTPUT_DIR" "$log" || rc=$?

  if (( ${rc:-0} != 0 )); then
    warn "[libadwaita] build failed; see $log"
    return 1
  fi
  ok "[libadwaita] built"
}

main() {
  parse_args "$@"
  require_cmd curl tar python3 dpkg sed

  python3 -c 'import tomllib' 2>/dev/null \
    || die "python3 >= 3.11 is required (tomllib)"

  if (( LIST_ONLY )); then show_plan; return 0; fi

  detect_engine >/dev/null || die "no usable container engine (install podman or docker)"
  mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

  local failed=0 built=0

  # GTK first: libadwaita cannot be configured without it.
  if build_gtk; then built=$((built+1)); else failed=$((failed+1)); fi

  # Only attempt libadwaita if GTK actually produced a package: building it
  # against the system GTK would silently produce the wrong thing.
  if (( failed == 0 )); then
    if build_libadwaita; then built=$((built+1)); else failed=$((failed+1)); fi
  else
    warn "skipping libadwaita: GTK did not build"
    failed=$((failed+1))
  fi

  echo
  info "results"
  local f
  shopt -s nullglob
  for f in "$OUTPUT_DIR"/*.deb; do
    printf '  %-58s %s\n' "$(basename "$f")" "$(human_size "$f")" >&2
  done
  shopt -u nullglob
  printf '\n  %d built, %d failed\n\n' "$built" "$failed" >&2
  (( failed == 0 ))
}

main "$@"
