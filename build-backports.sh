#!/usr/bin/env bash
#
# build-backports.sh — build the library backports Debian 13 needs for
# Celluloid 0.30, as private-prefix packages.
#
# Usage:
#   ./build-backports.sh [--list] [--rebuild] [name...]
#
# Produces three .deb files in dist/backports/:
#   libwayland-client0-backport   wayland 1.24  -> /opt/wl124
#   libgtk-4-1-backport           GTK 4.20      -> /opt/gtk420
#   libadwaita-1-0-backport       libadwaita 1.8 -> /opt/gtk420
#
# Why a separate script: these are not application packages. They exist only
# because Debian 13 ships GTK 4.18, and Celluloid 0.30 needs GTK >= 4.19.4 via
# libadwaita 1.8. See docs/backport-design.md for the measurements.
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly BACKPORTS_FILE="$SCRIPT_DIR/backports.toml"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/packaging.sh
source "$SCRIPT_DIR/lib/packaging.sh"
# shellcheck source=lib/container.sh
source "$SCRIPT_DIR/lib/container.sh"

VERBOSE=0
OUTPUT_DIR="$SCRIPT_DIR/dist/backports"
WORK_DIR="$SCRIPT_DIR/build/backports"
MAINTAINER="${DEBFULLNAME:-Celluloid Local Build} <${DEBEMAIL:-celluloid@localhost.localdomain}>"
declare -a REQUESTED=()
LIST_ONLY=0
REBUILD=0

usage() {
  cat <<'EOF'
Build the library backports Debian 13 needs for Celluloid 0.30.

USAGE
  ./build-backports.sh [options] [name...]

NAMES
  wayland, gtk, libadwaita    (default: all three, in dependency order)

OPTIONS
      --list        Show what would be built and exit
      --rebuild     Do not reuse cached source tarballs
  -o, --output DIR  Write .deb files here (default: ./dist/backports)
  -w, --work DIR    Scratch directory (default: ./build/backports)
      --verbose     Stream build logs
  -h, --help        Show this help
EOF
}

parse_args() {
  while (( $# )); do
    case "$1" in
         --list)      LIST_ONLY=1; shift ;;
         --rebuild)   REBUILD=1; shift ;;
      -o|--output)    OUTPUT_DIR="${2:?--output needs a value}"; shift 2 ;;
      -w|--work)      WORK_DIR="${2:?--work needs a value}"; shift 2 ;;
         --verbose)   VERBOSE=1; shift ;;
      -h|--help)      usage; exit 0 ;;
      -*)             die "unknown option: $1 (try --help)" ;;
      *)              REQUESTED+=("$1"); shift ;;
    esac
  done
}

# backport_field <name> <key> — read one value from backports.toml.
backport_field() {
  python3 - "$BACKPORTS_FILE" "$1" "$2" <<'PY'
import sys
import tomllib
path, name, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
if name not in data:
    sys.exit("unknown backport: %s" % name)
val = data[name].get(key)
if val is None:
    sys.exit("backport %s has no key %r" % (name, key))
if isinstance(val, list):
    print("\n".join(str(v) for v in val))
elif isinstance(val, bool):
    print("1" if val else "0")
else:
    print(val)
PY
}

all_backports() {
  python3 - "$BACKPORTS_FILE" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as fh:
    for name in tomllib.load(fh):
        print(name)
PY
}

# Build order matters: GTK needs wayland, libadwaita needs GTK.
build_order() {
  printf '%s\n' wayland gtk libadwaita
}

show_plan() {
  info "backport plan"
  printf '  %-12s %-10s %-28s %s\n' "NAME" "VERSION" "PACKAGE" "PREFIX" >&2
  local n v p pre
  while read -r n; do
    v=$(backport_field "$n" version)
    p=$(backport_field "$n" package)
    pre=$(backport_field "$n" prefix)
    printf '  %-12s %-10s %-28s %s\n' "$n" "$v" "$p" "$pre" >&2
  done < <(build_order)
}

# fetch <name> <dest> — download and extract, returning the source directory.
fetch_backport() {
  local name=$1 dest=$2 url tarball
  url=$(backport_field "$name" url)
  mkdir -p "$dest"
  tarball="$dest/$(basename "${url%%\?*}")"

  if (( REBUILD )) || [[ ! -f "$tarball" ]]; then
    step "downloading $(basename "$tarball")"
    local opts=(-fL --retry 3 --max-time 600)
    verbose && opts+=(--progress-bar) || opts+=(-sS)
    curl "${opts[@]}" -o "$tarball.part" "$url" || { rm -f "$tarball.part"; return 1; }
    mv -f "$tarball.part" "$tarball"
  else
    step "using cached $(basename "$tarball")"
  fi

  local unpack="$dest/unpack-$name"
  rm -rf "$unpack"; mkdir -p "$unpack"
  tar -xf "$tarball" -C "$unpack" || return 1

  # the archive holds exactly one top-level directory
  find "$unpack" -mindepth 1 -maxdepth 1 -type d | head -1
}

# generate_backport_debian <dest> <name> <version> <prefix> <package>
generate_backport_debian() {
  local dest=$1 name=$2 version=$3 prefix=$4 package=$5
  local tmpl="$SCRIPT_DIR/packaging/backport"
  local dversion="${version}-1~trixie"

  mkdir -p "$dest/debian/source"
  install -m 0644 "$tmpl/control"   "$dest/debian/control"
  install -m 0755 "$tmpl/rules"     "$dest/debian/rules"
  install -m 0644 "$tmpl/copyright" "$dest/debian/copyright"
  install -m 0644 "$tmpl/source/format" "$dest/debian/source/format"

  # Substitute the per-backport values.
  local f
  for f in "$dest/debian/control" "$dest/debian/copyright"; do
    sed -i \
      -e "s|@PACKAGE@|${package}|g" \
      -e "s|@VERSION@|${version}|g" \
      -e "s|@PREFIX@|${prefix}|g" \
      -e "s|@NAME@|${name}|g" \
      -e "s|@MAINTAINER@|${MAINTAINER}|g" \
      "$f"
  done
  # rules needs the prefix and schema flag too
  sed -i \
    -e "s|@PREFIX@|${prefix}|g" \
    -e "s|@VERSION@|${version}|g" \
    "$dest/debian/rules"
  chmod 0755 "$dest/debian/rules"

  local schemas
  schemas=$(backport_field "$name" skip_schemas 2>/dev/null || echo 0)
  sed -i "s|@SKIP_SCHEMAS@|${schemas}|g" "$dest/debian/rules"

  cat > "$dest/debian/changelog" <<EOF
${package} (${dversion}) trixie; urgency=medium

  * Backport of ${name} ${version} into ${prefix} for Celluloid 0.30.
  * Private prefix: does not replace any Debian-packaged library.

 -- ${MAINTAINER}  $(date -R)
EOF
  chmod 0644 "$dest/debian/changelog"
}

build_one() {
  local name=$1
  local version prefix package url engine meson_args
  local workroot srcroot outdir log stage extracted

  version=$(backport_field "$name" version)
  prefix=$(backport_field "$name" prefix)
  package=$(backport_field "$name" package)

  engine=$(detect_engine) || die "no usable container engine"

  workroot="$WORK_DIR/$name"
  outdir="$OUTPUT_DIR"
  log="$WORK_DIR/$name.log"
  mkdir -p "$workroot" "$outdir" "$WORK_DIR"

  info "[$name] ${version} -> ${prefix}"

  extracted=$(fetch_backport "$name" "$workroot/src") || die "[$name] fetch failed"

  # Lay out as <pkg>-<version> so dpkg-buildpackage has the expected shape.
  stage="$workroot/stage"
  rm -rf "$stage"; mkdir -p "$stage"
  mv "$extracted" "$stage/${package%-backport}-${version}"

  generate_backport_debian "$stage/${package%-backport}-${version}" \
    "$name" "$version" "$prefix" "$package"
  # move debian/ into place relative to the source dir
  mv "$stage/${package%-backport}-${version}/debian" \
     "$stage/${package%-backport}-${version}/debian" 2>/dev/null || true

  step "building in debian:13"
  build_backport_in_container "$engine" "$stage" "$outdir" "$log" \
    "$prefix" "$(backport_field "$name" meson_args | tr '\n' ' ')" \
    "$(backport_field "$name" skip_schemas 2>/dev/null || echo 0)"

  ok "[$name] done"
}

main() {
  parse_args "$@"
  require_cmd curl tar python3 dpkg sed

  if (( LIST_ONLY )); then show_plan; return 0; fi

  mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

  local failed=0 built=0 n
  local -a queue=()
  if (( ${#REQUESTED[@]} )); then
    queue=("${REQUESTED[@]}")
  else
    mapfile -t queue < <(build_order)
  fi

  for n in "${queue[@]}"; do
    if build_one "$n"; then built=$((built+1)); else failed=$((failed+1)); fi
  done

  echo
  info "results"
  local f
  shopt -s nullglob
  for f in "$OUTPUT_DIR"/*.deb; do
    printf '  %-56s %s\n' "$(basename "$f")" "$(human_size "$f")" >&2
  done
  shopt -u nullglob
  printf '\n  %d built, %d failed\n\n' "$built" "$failed" >&2
  (( failed == 0 ))
}

main "$@"
