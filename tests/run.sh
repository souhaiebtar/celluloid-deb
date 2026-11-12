#!/usr/bin/env bash
#
# tests/run.sh — fast checks that do not need a container.
#
# Covers the parts most likely to break silently: version resolution, packaging
# generation, and the meson floor parser. A full build is exercised by CI.
#
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
readonly ROOT
readonly SUITES_FILE="$ROOT/suites.toml"

pass=0 fail=0

t() { # t <description> <command...>
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  FAIL %s\n' "$desc"; fail=$((fail+1))
  fi
}

eq() { # eq <description> <expected> <actual>
  local desc=$1 want=$2 got=$3
  if [[ "$want" == "$got" ]]; then
    printf '  ok   %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  FAIL %s\n    expected: %s\n    actual:   %s\n' "$desc" "$want" "$got"
    fail=$((fail+1))
  fi
}

# ------------------------------------------------------------- unit tests ---
source "$ROOT/lib/common.sh"
source "$ROOT/lib/resolve.sh"
source "$ROOT/lib/packaging.sh"
source "$ROOT/lib/source.sh"
source "$ROOT/lib/container.sh"

echo "version helpers"
eq "normalize strips v"          "0.30"   "$(normalize_version v0.30)"
eq "normalize no-op without v"   "0.30"   "$(normalize_version 0.30)"
t  "1.10.0 >= 1.8.0"             version_ge 1.10.0 1.8.0
t  "4.18.6 >= 4.16.0"            version_ge 4.18.6 4.16.0
t  "1.7.6 < 1.8.0"               bash -c '! version_ge 1.7.6 1.8.0'
t  "4.8.3 < 4.16.0"              bash -c '! version_ge 4.8.3 4.16.0'

echo "debian version strings"
eq "revision has suite suffix"   "1~trixie"  "$(debian_revision trixie)"
eq "full version"                "0.29-1~trixie" "$(debian_version 0.29 trixie)"
# the ~suite suffix must sort BELOW a plain Debian upload of the same version
t  "local build sorts below archive upload" \
   dpkg --compare-versions "0.29-1~trixie" lt "0.29-1"
# ...but ABOVE the previous upstream release
t  "local build sorts above older upstream" \
   dpkg --compare-versions "0.29-1~trixie" gt "0.28-2"

echo "backport-aware resolution"
# trixie's own GTK is too old for 0.30; with backports it becomes buildable.
eq "trixie without backports sees GTK 4.18" "4.18.6 1.7.6 0.40.0" \
  "$(BACKPORTS_AVAILABLE=0 suite_libs trixie)"
eq "trixie with backports sees GTK 4.20" "4.20.4 1.8.8 0.40.0" \
  "$(BACKPORTS_AVAILABLE=1 suite_libs trixie)"
# Suites with no backport_* keys must be unaffected.
eq "bookworm unaffected by backports" "4.8.3 1.2.2 0.32.0" \
  "$(BACKPORTS_AVAILABLE=1 suite_libs bookworm)"
eq "sid unaffected by backports" "4.24.1 1.10.0 0.42.0" \
  "$(BACKPORTS_AVAILABLE=1 suite_libs sid)"
# The backported floors must actually satisfy Celluloid 0.30's requirements.
read -r bgtk badw _ < <(BACKPORTS_AVAILABLE=1 suite_libs trixie)
t "backport GTK satisfies 0.30 (gtk>=4.16, adw>=1.8)" \
  bash -c "dpkg --compare-versions '$bgtk' ge 4.16.0 && dpkg --compare-versions '$badw' ge 1.8.0"

echo "suite metadata"
eq "bookworm release"    "12"     "$(suite_setting bookworm release)"
eq "trixie release"      "13"     "$(suite_setting trixie release)"
eq "sid distribution"    "sid"    "$(suite_setting sid distribution)"
t  "unknown suite rejected" \
   bash -c '! suite_setting nosuchsuite image 2>/dev/null'

echo "meson floor parser"
parser="$ROOT/lib/parse-meson.py"
eq "0.30 floors" "4.16.0	1.8.0	1.107" \
  "$(printf "%s\n" "libgtk = dependency('gtk4', version: '>=4.16.0')" \
      "dependency('mpv', version: '>= 1.107')" \
      "dependency('libadwaita-1', version: '>= 1.8.0')" | python3 "$parser")"
eq "no version constraint" "0	0	0" \
  "$(printf "%s\n" "dependency('gtk4')" "dependency('mpv')" | python3 "$parser")"
eq "spacing variants" "4.6.1	1.2.0	0" \
  "$(printf "%s\n" "dependency('gtk4', version: '>= 4.6.1')" \
      "dependency('libadwaita-1', version:'>=1.2.0')" | python3 "$parser")"
t "empty input is an error" bash -c "printf '' | python3 '$parser' >/dev/null 2>&1 && exit 1 || exit 0"

echo "build image cache"
# The tag must be a pure function of the recipe, so unrelated runs reuse it...
a=$(build_image_ref trixie docker.io/library/debian:13 2>/dev/null)
b=$(build_image_ref trixie docker.io/library/debian:13 2>/dev/null)
eq "tag is stable for the same recipe" "$a" "$b"
t  "tag is non-empty" test -n "$a"
# ...and a different base image must produce a different tag, or a stale image
# would be silently reused across suites.
c=$(build_image_ref trixie docker.io/library/debian:12 2>/dev/null)
t  "different base image changes the tag" bash -c "[ '$a' != '$c' ]"
# Suites are separate images even with the same base.
d=$(build_image_ref bookworm docker.io/library/debian:13 2>/dev/null)
t  "different suite changes the tag" bash -c "[ '$a' != '$d' ]"
# A dependency change must invalidate the cache.
before=$(build_image_ref trixie docker.io/library/debian:13 2>/dev/null)
BUILD_DEPS+=("zzz-nonexistent-package")
after=$(build_image_ref trixie docker.io/library/debian:13 2>/dev/null)
t  "changing the dependency list changes the tag" bash -c "[ '$before' != '$after' ]"
unset 'BUILD_DEPS[-1]'

# The rendered recipe must be a valid Dockerfile with no unsubstituted tokens.
rendered=$(mktemp)
if render_dockerfile docker.io/library/debian:13 "$rendered" 2>/dev/null; then
  t "rendered recipe starts with FROM" bash -c "head -20 '$rendered' | grep -q '^FROM docker.io/library/debian:13'"
  t "no unsubstituted tokens in recipe" bash -c "! grep -q '@[A-Z_]*@' '$rendered'"
  t "recipe installs the dependencies" bash -c "grep -q 'libadwaita-1-dev' '$rendered'"
  t "recipe cleans the apt cache" bash -c "grep -q 'rm -rf /var/lib/apt/lists' '$rendered'"
else
  printf '  FAIL could not render recipe\n'; fail=$((fail+1))
fi
rm -f "$rendered"

echo "packaging generation"
tmp=$(mktemp -d)
mkdir -p "$tmp/src"
if generate_debian_dir "$tmp/src" 0.29 trixie "Test <t@example.com>" 2>/dev/null; then
  t "control file created"   test -f "$tmp/src/debian/control"
  t "rules is executable"    test -x "$tmp/src/debian/rules"
  t "source format is quilt" grep -qx "3.0 (quilt)" "$tmp/src/debian/source/format"
  # debhelper compat must come from Build-Depends only
  t "no debian/compat file"  bash -c "! test -e '$tmp/src/debian/compat'"
  t "compat in Build-Depends" grep -q "debhelper-compat (= 13)" "$tmp/src/debian/control"
  t "changelog version"      grep -q "^celluloid (0.29-1~trixie) trixie;" "$tmp/src/debian/changelog"
  t "no unsubstituted tokens" bash -c "! grep -rq '@[A-Z_]*@' '$tmp/src/debian'"
  t "maintainer substituted" grep -q "Test <t@example.com>" "$tmp/src/debian/control"
else
  printf '  FAIL could not generate packaging\n'; fail=$((fail+1))
fi
rm -rf "$tmp"

# ----------------------------------------------------- resolution (net) ----
# Skipped offline: these need the GitHub API.
if curl -fsS --max-time 8 https://api.github.com >/dev/null 2>&1; then
  echo "version resolution (network)"
  for pair in "bookworm:0.27" "trixie:0.29" "sid:0.30"; do
    suite=${pair%%:*}; want=${pair##*:}
    got=$(resolve_version "$suite" "" 0 2>/dev/null | cut -f1)
    # sid tracks upstream, so accept anything >= 0.30 there
    if [[ "$suite" == "sid" ]]; then
      if version_ge "${got:-0}" "$want"; then
        printf '  ok   %s resolves to %s (>= %s)\n' "$suite" "$got" "$want"; pass=$((pass+1))
      else
        printf '  FAIL %s resolved to %s, expected >= %s\n' "$suite" "${got:-none}" "$want"; fail=$((fail+1))
      fi
    else
      eq "$suite resolves to $want" "$want" "$got"
    fi
  done
  t "pinned version honoured" bash -c \
    "out=\$('$ROOT/build.sh' --version 0.28 --list 2>&1); \
     printf '%s' \"\$out\" | grep -q 'trixie[[:space:]]*0\.28 '"

  # Fallback must step *backwards* in time. Releases are listed newest-first,
  # so prev_tag(0.30) must be 0.29 and never the reverse.
  echo "fallback ordering (network)"
  eq "prev_tag(0.30) is 0.29" "v0.29" "$(prev_tag v0.30)"
  eq "prev_tag(0.29) is 0.28" "v0.28" "$(prev_tag v0.29)"
  t  "prev_tag of the oldest known release fails" \
     bash -c "! prev_tag \$(github_releases | tail -1 | cut -f1) >/dev/null 2>&1"
else
  echo "version resolution: skipped (no network)"
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
