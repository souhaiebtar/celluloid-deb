#!/usr/bin/env bash
# Version resolution: decide which upstream Celluloid release to package for a
# given Debian suite.
#
# Celluloid bumps its GTK/libadwaita floor every few releases, so "latest" is
# not always buildable on a given Debian release. Rather than pinning versions
# in a table that silently rots, this resolves dynamically:
#
#   1. list upstream releases from the GitHub API (or a pinned list)
#   2. read each release's meson.build dependency floors
#   3. keep the newest release that the suite's libraries satisfy
#   4. fall back one release at a time if the container build disproves step 3
#
# Resolution is deliberately separate from building: resolving is cheap and
# network-only, building is expensive and container-only.

if [[ -n "${_CELLULOID_RESOLVE_SH:-}" ]]; then return 0; fi
_CELLULOID_RESOLVE_SH=1

GITHUB_REPO="${GITHUB_REPO:-celluloid-player/celluloid}"

# Upstream signing key used to verify tarballs. Fetched from the maintainer's
# GitHub profile, which is the source the project documents.
UPSTREAM_KEY_URL="${UPSTREAM_KEY_URL:-https://github.com/gnome-mpv.gpg}"

# ------------------------------------------------------------------- api ---
# github_releases — newline-separated "tag<TAB>tarball_url<TAB>sig_url",
# newest first. Falls back to a small built-in list when the API is
# unreachable so an offline run can still build a known-good version.
#
# The result is cached for the run: resolution calls this several times per
# suite, and the unauthenticated GitHub API allows only 60 requests per hour,
# which is easy to exhaust on a three-suite build.
github_releases() {
  if [[ -n "${_RELEASES_CACHE:-}" ]]; then
    printf '%s\n' "$_RELEASES_CACHE"
    return 0
  fi

  local json out=""
  if json=$(curl -fsSL --max-time 30 \
        "https://api.github.com/repos/${GITHUB_REPO}/releases?per_page=30" 2>/dev/null); then
    out=$(printf '%s' "$json" | python3 -c '
import json,sys
try:
    rel = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for r in rel:
    if r.get("draft") or r.get("prerelease"):
        continue
    tag = r.get("tag_name") or ""
    assets = {a["name"]: a["browser_download_url"] for a in r.get("assets") or []}
    tar = sig = ""
    for n,u in assets.items():
        if n.endswith(".tar.xz"):
            tar = u
        elif n.endswith(".tar.xz.asc"):
            sig = u
    if tag and tar:
        print("%s\t%s\t%s" % (tag, tar, sig))
')
  fi

  if [[ -z "$out" ]]; then
    warn "GitHub API unavailable or rate-limited; using built-in release list" >&2
    # Last-resort known-good versions. Kept short on purpose.
    out=$(cat <<'EOF'
v0.30	https://github.com/celluloid-player/celluloid/releases/download/v0.30/celluloid-0.30.tar.xz	https://github.com/celluloid-player/celluloid/releases/download/v0.30/celluloid-0.30.tar.xz.asc
v0.29	https://github.com/celluloid-player/celluloid/releases/download/v0.29/celluloid-0.29.tar.xz	https://github.com/celluloid-player/celluloid/releases/download/v0.29/celluloid-0.29.tar.xz.asc
v0.28	https://github.com/celluloid-player/celluloid/releases/download/v0.28/celluloid-0.28.tar.xz	https://github.com/celluloid-player/celluloid/releases/download/v0.28/celluloid-0.28.tar.xz.asc
v0.27	https://github.com/celluloid-player/celluloid/releases/download/v0.27/celluloid-0.27.tar.xz	https://github.com/celluloid-player/celluloid/releases/download/v0.27/celluloid-0.27.tar.xz.asc
v0.26	https://github.com/celluloid-player/celluloid/releases/download/v0.26/celluloid-0.26.tar.xz	https://github.com/celluloid-player/celluloid/releases/download/v0.26/celluloid-0.26.tar.xz.asc
EOF
)
  fi

  _RELEASES_CACHE=$out
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------- floors ---
# meson_floors <tag> — print "gtk4<TAB>libadwaita<TAB>libmpv" dependency floors
# declared by that release. Empty output means "unknown, assume buildable".
meson_floors() {
  local tag=$1 build parser
  parser="$(dirname -- "${BASH_SOURCE[0]}")/parse-meson.py"

  build=$(curl -fsSL --max-time 20 \
    "https://raw.githubusercontent.com/${GITHUB_REPO}/${tag}/src/meson.build" 2>/dev/null) || return 0
  [[ -n "$build" ]] || return 0

  printf '%s' "$build" | python3 "$parser" 2>/dev/null || return 0
}

# ------------------------------------------------------------- resolver ---
# Libraries shipped by a suite, as "gtk4 libadwaita libmpv".
suite_libs() {
  local suite=$1
  python3 - "$SUITES_FILE" "$suite" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("python3 >= 3.11 is required (tomllib)")
path, suite = sys.argv[1], sys.argv[2]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
if suite not in data:
    sys.exit("unknown suite: %s" % suite)
s = data[suite]
print(s.get("gtk4", "0"), s.get("libadwaita", "0"), s.get("libmpv", "0"))
PY
}

# suite_setting <suite> <key> — read one value from suites.toml.
suite_setting() {
  python3 - "$SUITES_FILE" "$1" "$2" <<'PY'
import sys
try:
    import tomllib
except ModuleNotFoundError:
    sys.exit("python3 >= 3.11 is required (tomllib)")
path, suite, key = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "rb") as fh:
    data = tomllib.load(fh)
if suite not in data:
    sys.exit("unknown suite: %s" % suite)
val = data[suite].get(key)
if val is None:
    sys.exit("suite %s has no key %r" % (suite, key))
print(val)
PY
}

# resolve_version <suite> [pinned_version] [max_versions_to_try]
#
# Prints "version<TAB>tag<TAB>tarball<TAB>sig" for the newest release that the
# suite's library ceilings satisfy. A pinned version short-circuits resolution.
resolve_version() {
  local suite=$1 pinned=${2:-} try_limit=${3:-3}
  local gtk4 adw mpv

  read -r gtk4 adw mpv < <(suite_libs "$suite") || return 1

  if [[ -n "$pinned" ]]; then
    local tag="v$(normalize_version "$pinned")" tar sig
    while IFS=$'\t' read -r t u s; do
      [[ "$t" == "$tag" ]] && { tar=$u; sig=$s; break; }
    done < <(github_releases)
    if [[ -z "${tar:-}" ]]; then
      # Not in the release list (e.g. an unreleased branch): build the URL.
      tar="https://github.com/${GITHUB_REPO}/releases/download/${tag}/celluloid-${pinned}.tar.xz"
      sig="${tar}.asc"
    fi
    printf '%s\t%s\t%s\t%s\n' "$pinned" "$tag" "$tar" "$sig"
    return 0
  fi

  local tried=0 tag tar sig ver floors want_gtk want_adw want_mpv
  local fallback="" fb_ver="" fb_tag="" fb_tar="" fb_sig=""
  while IFS=$'\t' read -r tag tar sig; do
    [[ -n "$tag" ]] || continue
    # try_limit 0 means "walk the whole release list"; oldstable often needs
    # several steps back before the GTK/libadwaita floors are met.
    if (( try_limit > 0 && tried >= try_limit )); then break; fi
    ver=$(normalize_version "$tag")

    floors=$(meson_floors "$tag")
    if [[ -z "$floors" ]]; then
      # Metadata unavailable (network hiccup, tag without src/meson.build).
      # Do not guess: remember the newest such release as a last resort and
      # keep looking for one we can actually reason about.
      warn "could not read meson floors for $tag" >&2
      if [[ -z "$fallback" ]]; then
        fallback=1; fb_ver=$ver; fb_tag=$tag; fb_tar=$tar; fb_sig=$sig
      fi
      continue
    fi
    IFS=$'\t' read -r want_gtk want_adw want_mpv <<<"$floors"

    if version_ge "$gtk4" "$want_gtk" && version_ge "$adw" "$want_adw"; then
      printf '%s\t%s\t%s\t%s\n' "$ver" "$tag" "$tar" "$sig"
      return 0
    fi

    step "$suite: skipping $ver (needs gtk4>=$want_gtk libadwaita>=$want_adw; suite has $gtk4 / $adw)" >&2
    tried=$(( tried + 1 ))
  done < <(github_releases)

  # Nothing could be confirmed from metadata. Rather than fail outright, offer
  # the newest unverifiable release and let the container build decide.
  if [[ -n "$fallback" ]]; then
    warn "$suite: no release confirmed from metadata; will try $fb_ver in the container" >&2
    printf '%s\t%s\t%s\t%s\n' "$fb_ver" "$fb_tag" "$fb_tar" "$fb_sig"
    return 0
  fi

  return 1
}

# prev_tag <tag> — the release *older* than <tag> in upstream history.
#
# github_releases lists newest-first, so an older release appears *after* the
# target. Two passes: find the target, then return the next line.
prev_tag() {
  local tag=$1 seen=0
  while IFS=$'\t' read -r t _ _; do
    [[ -n "$t" ]] || continue
    if (( seen )); then
      printf '%s' "$t"
      return 0
    fi
    [[ "$t" == "$tag" ]] && seen=1
  done < <(github_releases)
  return 1
}

# release_urls <tag> — print "tarball<TAB>sig" for a tag.
release_urls() {
  local tag=$1 ver tar="" sig=""
  ver=$(normalize_version "$tag")
  while IFS=$'\t' read -r t u s; do
    [[ "$t" == "$tag" ]] && { tar=$u; sig=$s; break; }
  done < <(github_releases)
  [[ -n "$tar" ]] || tar="https://github.com/${GITHUB_REPO}/releases/download/${tag}/celluloid-${ver}.tar.xz"
  [[ -n "$sig" ]] || sig="${tar}.asc"
  printf '%s\t%s\n' "$tar" "$sig"
}
