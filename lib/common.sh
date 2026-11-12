#!/usr/bin/env bash
# Shared helpers: logging, error handling, small utilities.
# Sourced by build.sh; not executable on its own.
#
# This file is sourced, so it must not call `set -e` on its own path —
# build.sh owns the option handling.

if [[ -n "${_CELLULOID_COMMON_SH:-}" ]]; then
  return 0
fi
_CELLULOID_COMMON_SH=1

# ---------------------------------------------------------------- colours ---
# Disable colour when stdout is not a terminal or NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET= C_BOLD= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_CYAN=
fi

# All diagnostics go to stderr so that command substitution stays clean.
log()   { printf '%s\n' "$*" >&2; }
info()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*" >&2; }
step()  { printf '%s  ->%s %s\n' "$C_CYAN" "$C_RESET" "$*" >&2; }
ok()    { printf '%s  ok%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn()  { printf '%swarn%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()   { printf '%serr %s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Keep the last command's output out of the log unless verbose.
verbose() { [[ "${VERBOSE:-0}" -eq 1 ]]; }

# ------------------------------------------------------------- utilities ---
# require_cmd <name>... — fail early with a readable message.
require_cmd() {
  local missing=() c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die "missing required command(s): ${missing[*]}"
  fi
}

# normalize_version <string> — strip a leading "v" from an upstream tag.
normalize_version() {
  local v=$1
  v=${v#v}
  printf '%s' "$v"
}

# version_ge <a> <b> — true when a >= b using dpkg semantics.
version_ge() {
  dpkg --compare-versions "$1" ge "$2"
}

# version_gt <a> <b>
version_gt() {
  dpkg --compare-versions "$1" gt "$2"
}

# debian_arch — host architecture as Debian names it.
debian_arch() {
  dpkg --print-architecture
}

# human_size <path> — "1.2M" style, for the final summary.
human_size() {
  local bytes
  bytes=$(stat -c %s "$1" 2>/dev/null) || { printf '?'; return; }
  numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || printf '%sB' "$bytes"
}

# repo_root — absolute path of the project directory.
repo_root() {
  cd -- "$(dirname -- "${BASH_SOURCE[1]}")/.." >/dev/null 2>&1 && pwd
}
