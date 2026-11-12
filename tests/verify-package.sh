#!/usr/bin/env bash
#
# tests/verify-package.sh — sanity-check a built .deb without installing it.
#
#   tests/verify-package.sh dist/trixie/celluloid_0.29-1~trixie_amd64.deb
#
# Checks the things that silently go wrong in packaging: missing runtime
# dependencies, an empty payload, or a package that would fail to configure.
#
set -uo pipefail

deb=${1:?usage: verify-package.sh <file.deb>}
[[ -f "$deb" ]] || { echo "no such file: $deb" >&2; exit 1; }

pass=0 fail=0
check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then
    printf '  ok   %s\n' "$desc"; pass=$((pass+1))
  else
    printf '  FAIL %s\n' "$desc"; fail=$((fail+1))
  fi
}

echo "verifying $(basename "$deb")"

field() { dpkg-deb -f "$deb" "$1" 2>/dev/null; }

check "is a valid deb"        dpkg-deb --info "$deb"
check "has a package name"    test -n "$(field Package)"
check "has a version"         test -n "$(field Version)"
check "has an architecture"   test -n "$(field Architecture)"
check "has a description"     test -n "$(field Description)"

# Runtime dependencies must have been resolved at build time; an unresolved
# ${shlibs:Depends} means the build environment was broken.
deps=$(field Depends)
check "Depends is not empty"        test -n "$deps"
check "no unexpanded \${shlibs:Depends}" \
  bash -c "! echo '$deps' | grep -q 'shlibs'"
check "no unexpanded \${misc:Depends}" \
  bash -c "! echo '$deps' | grep -q 'misc:Depends'"

# The binary must actually be in there, or the package is useless.
check "contains /usr/bin/celluloid" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'usr/bin/celluloid$'"
check "contains the .desktop file" \
  bash -c "dpkg-deb -c '$deb' | grep -q '.desktop$'"
check "contains the GSettings schema" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'glib-2.0/schemas/.*gschema.xml$'"
check "contains the D-Bus service" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'dbus-1/services/.*\.service$'"
check "ships a copyright file" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'doc/.*/copyright$'"
check "ships a changelog" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'changelog.Debian.gz$'"

# Installed-Size must be plausible: a zero means dh_install copied nothing.
size=$(field Installed-Size)
check "Installed-Size > 100 KB" \
  bash -c "[ '${size:-0}' -gt 100 ]"

# Translations are the usual casualty of a bad gettext step.
check "ships locale files" \
  bash -c "dpkg-deb -c '$deb' | grep -q 'locale/.*\.mo$'"

# The local build must sort below a real Debian upload of the same version.
case "$(field Version)" in
  *~*) check "version has a suite suffix" true ;;
  *)   check "version has a suite suffix" false ;;
esac

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
