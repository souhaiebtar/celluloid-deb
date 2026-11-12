#!/usr/bin/env bash
#
# build.sh — build Debian packages for Celluloid from official upstream releases.
#
# Usage:
#   ./build.sh [options] [suite...]
#
# Examples:
#   ./build.sh                      # every configured suite
#   ./build.sh trixie               # just Debian 13
#   ./build.sh --latest sid         # newest release, no dependency clamping
#   ./build.sh --version 0.30 sid   # one exact upstream version
#   ./build.sh --list               # show what would be built, build nothing
#
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
readonly SUITES_FILE="$SCRIPT_DIR/suites.toml"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/resolve.sh
source "$SCRIPT_DIR/lib/resolve.sh"
# shellcheck source=lib/source.sh
source "$SCRIPT_DIR/lib/source.sh"
# shellcheck source=lib/packaging.sh
source "$SCRIPT_DIR/lib/packaging.sh"
# shellcheck source=lib/container.sh
source "$SCRIPT_DIR/lib/container.sh"

# --------------------------------------------------------------- defaults ---
VERBOSE=0
VERIFY=1
LIST_ONLY=0
KEEP_WORK=0
PINNED_VERSION=""
FORCE_LATEST=0
OUTPUT_DIR="$SCRIPT_DIR/dist"
WORK_DIR="$SCRIPT_DIR/build"
MAINTAINER="${DEBFULLNAME:-Celluloid Local Build}"
MAINTAINER_EMAIL="${DEBEMAIL:-celluloid@localhost.localdomain}"
UPSTREAM_FINGERPRINT="${UPSTREAM_FINGERPRINT:-4BA23A4D2F798D926C7A0E0D0F9039A19BE2326C}"
declare -a REQUESTED_SUITES=()

usage() {
  cat <<'EOF'
Build Debian packages for Celluloid from official upstream releases.

USAGE
  ./build.sh [options] [suite...]

SUITES
  bookworm   Debian 12 (oldstable)
  trixie     Debian 13 (stable)
  sid        Debian unstable
  With no suite given, every suite in suites.toml is built.

OPTIONS
  -v, --version VERSION   Build this exact upstream version (e.g. 0.30).
  -l, --latest            Use the newest upstream release on every suite,
                          without checking library ceilings.
  -n, --no-verify         Do not GPG-verify the source tarball. Not advised.
  -o, --output DIR        Write .deb files here (default: ./dist).
  -w, --work DIR          Scratch directory (default: ./build).
  -k, --keep              Keep the extracted source tree after building.
      --list              Print the resolved plan and exit.
      --maintainer "NAME <email>"
                          Maintainer recorded in the generated changelog.
      --engine NAME       Force a container engine (podman or docker).
      --verbose           Stream the full container build log.
  -h, --help              Show this help.

ENVIRONMENT
  CONTAINER_ENGINE        Default engine (podman or docker).
  UPSTREAM_FINGERPRINT    Expected GPG key fingerprint of the release signer.

EXAMPLES
  ./build.sh                       Build every suite.
  ./build.sh trixie                Build only Debian 13.
  ./build.sh --list                Show the resolved plan.
  ./build.sh --latest sid          Force the newest release on sid.
  ./build.sh --version 0.29 trixie Build one exact version.
EOF
}

# ---------------------------------------------------------------- parsing ---
parse_args() {
  while (( $# )); do
    case "$1" in
      -v|--version)     PINNED_VERSION="${2:?--version needs a value}"; shift 2 ;;
      -l|--latest)      FORCE_LATEST=1; shift ;;
      -n|--no-verify)   VERIFY=0; shift ;;
      -o|--output)      OUTPUT_DIR="${2:?--output needs a value}"; shift 2 ;;
      -w|--work)        WORK_DIR="${2:?--work needs a value}"; shift 2 ;;
      -k|--keep)        KEEP_WORK=1; shift ;;
         --list)        LIST_ONLY=1; shift ;;
         --maintainer)  MAINTAINER="${2:?--maintainer needs a value}"; shift 2 ;;
         --engine)      CONTAINER_ENGINE="${2:?--engine needs a value}"; export CONTAINER_ENGINE; shift 2 ;;
         --verbose)     VERBOSE=1; shift ;;
      -h|--help)        usage; exit 0 ;;
      --)               shift; while (( $# )); do REQUESTED_SUITES+=("$1"); shift; done ;;
      -*)               die "unknown option: $1 (try --help)" ;;
      *)                REQUESTED_SUITES+=("$1"); shift ;;
    esac
  done

  # Maintainer string may be split across name/email env vars.
  if [[ "$MAINTAINER" != *"<"* ]]; then
    MAINTAINER="$MAINTAINER <$MAINTAINER_EMAIL>"
  fi
}

# ------------------------------------------------------------------ setup ---
check_prerequisites() {
  require_cmd curl tar python3 dpkg sed find
  python3 - <<'PY' || die "python3 >= 3.11 is required for tomllib"
import sys, tomllib  # noqa: F401
sys.exit(0 if sys.version_info >= (3, 11) else 1)
PY
  [[ -f "$SUITES_FILE" ]] || die "missing suites.toml at $SUITES_FILE"
}

# all_suites — suites declared in suites.toml, in file order.
all_suites() {
  python3 - "$SUITES_FILE" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as fh:
    for name in tomllib.load(fh):
        print(name)
PY
}

# resolve_plan — decide the version to build for each selected suite.
# Emits rows: suite<TAB>version<TAB>tag<TAB>tarball<TAB>sig
build_plan() {
  local suites=() s row pinned
  if (( ${#REQUESTED_SUITES[@]} )); then
    suites=("${REQUESTED_SUITES[@]}")
  else
    mapfile -t suites < <(all_suites)
  fi
  (( ${#suites[@]} )) || die "no suites requested"

  for s in "${suites[@]}"; do
    # validate the suite name early with a readable message
    if ! suite_setting "$s" image >/dev/null 2>&1; then
      die "unknown suite '$s' (known: $(all_suites | tr '\n' ' '))"
    fi

    if (( FORCE_LATEST )); then
      # take the newest release regardless of the suite's library versions
      local tag tar sig
      IFS=$'\t' read -r tag tar sig < <(github_releases | head -1)
      [[ -n "$tag" ]] || die "could not determine the latest release"
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "$s" "$(normalize_version "$tag")" "$tag" "$tar" "$sig"
      continue
    fi

    pinned="$PINNED_VERSION"
    if ! row=$(resolve_version "$s" "$pinned" 0); then
      warn "no buildable release found for $s"
      continue
    fi
    printf '%s\t%s\n' "$s" "$row"
  done
}

# ------------------------------------------------------------------- plan ---
print_plan() {
  local suite ver tag tar sig
  info "build plan"
  printf '  %-10s %-10s %-12s %s\n' "SUITE" "VERSION" "DEB VERSION" "RUNTIME LIBS" >&2
  while IFS=$'\t' read -r suite ver tag tar sig; do
    [[ -n "$suite" ]] || continue
    local gtk4 adw mpv
    read -r gtk4 adw mpv < <(suite_libs "$suite")
    printf '  %-10s %-10s %-12s gtk4 %s / adw %s / mpv %s\n' \
      "$suite" "$ver" "$(debian_version "$ver" "$suite")" "$gtk4" "$adw" "$mpv" >&2
  done < <(build_plan)
}

# ------------------------------------------------------------------ build ---
build_one() {
  local suite=$1 ver=$2 tag=$3 tar_url=$4 sig_url=$5
  local engine image workroot srcdir outdir log
  local attempt tag_try tar_try sig_try ver_try

  engine=$(detect_engine) || die "no usable container engine (install podman or docker)"
  image=$(suite_setting "$suite" image)

  workroot="$WORK_DIR/$suite"
  srcdir="$workroot/src"
  outdir="$OUTPUT_DIR/$suite"
  log="$WORK_DIR/$suite.log"

  rm -rf "$workroot"
  mkdir -p "$srcdir" "$outdir" "$WORK_DIR"

  info "[$suite] Celluloid $ver  ($(debian_version "$ver" "$suite"))"
  ensure_image "$engine" "$image" || die "could not obtain image $image"

  attempt=0
  tag_try=$tag; tar_try=$tar_url; sig_try=$sig_url; ver_try=$ver

  while :; do
    step "fetching source for $tag_try"
    local tarball
    if ! tarball=$(fetch_source "$tar_try" "$sig_try" "$srcdir" "$workroot" \
                    "$VERIFY" "$UPSTREAM_FINGERPRINT"); then
      # A failed signature check is fatal: it means the tarball is not what
      # upstream published, so nothing else in this run can be trusted.
      if (( VERIFY )); then
        die "[$suite] refused to build unverified source for $tag_try"
      fi
      warn "[$suite] could not download source for $tag_try"
      return 1
    fi

    local extracted
    if ! extracted=$(extract_source "$tarball" "$workroot/unpack"); then
      warn "[$suite] could not extract $(basename "$tarball")"
      return 1
    fi

    step "generating debian/ packaging"
    if ! generate_debian_dir "$extracted" "$ver_try" "$suite" "$MAINTAINER"; then
      warn "[$suite] could not generate packaging"
      return 1
    fi

    # Lay the tree where the container expects it.
    local stage="$workroot/stage"
    rm -rf "$stage"; mkdir -p "$stage"
    mv "$extracted" "$stage/celluloid-$ver_try"

    step "building in $image"
    if build_in_container "$engine" "$image" "$stage" "$outdir" "$log"; then
      ok "[$suite] built $(debian_version "$ver_try" "$suite")"
      fix_ownership "$workroot"
      (( KEEP_WORK )) || rm -rf "$stage" "$workroot/unpack"
      return 0
    fi

    # The container is the authority: if meson rejected the version, step back
    # one release and try again, up to a small limit.
    attempt=$(( attempt + 1 ))
    if (( attempt > 2 )); then
      warn "[$suite] build failed for $tag_try after $attempt attempts"
      warn "[$suite] see $log"
      return 1
    fi

    local prev
    if ! prev=$(prev_tag "$tag_try"); then
      warn "[$suite] no older release available to fall back to"
      warn "[$suite] see $log"
      return 1
    fi
    warn "[$suite] $tag_try did not build; retrying with $prev"

    ver_try=$(normalize_version "$prev")
    tag_try=$prev
    IFS=$'\t' read -r tar_try sig_try < <(release_urls "$prev")
    rm -rf "$workroot/unpack" "$workroot/stage" "$outdir"/*
  done
}

# ------------------------------------------------------------------- main ---
main() {
  parse_args "$@"
  check_prerequisites

  if (( LIST_ONLY )); then
    print_plan
    return 0
  fi

  local engine
  engine=$(detect_engine) || die "no usable container engine (install podman or docker)"
  info "engine: $engine"

  mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

  local failed=0 built=0
  local suite ver tag tar sig

  while IFS=$'\t' read -r suite ver tag tar sig; do
    [[ -n "$suite" ]] || continue
    if build_one "$suite" "$ver" "$tag" "$tar" "$sig"; then
      built=$(( built + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  done < <(build_plan)

  # Summary
  echo
  info "results"
  local f
  shopt -s nullglob
  for f in "$OUTPUT_DIR"/*/*.deb; do
    printf '  %-58s %s\n' "$(basename "$f")" "$(human_size "$f")" >&2
  done
  shopt -u nullglob

  printf '\n  %d built, %d failed\n\n' "$built" "$failed" >&2

  (( failed == 0 )) || return 1
  (( built > 0 ))   || { warn "nothing was built"; return 1; }
  return 0
}

main "$@"
