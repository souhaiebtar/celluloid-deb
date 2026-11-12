#!/usr/bin/env bash
# Generates a Debian packaging tree for a Celluloid upstream release.
#
# The upstream tarball ships no debian/ directory, so we synthesise one here at
# build time. Keeping it generated (rather than committed per version) means the
# control file and changelog always match the version and suite being built.
#
# Layout produced in <dest>/debian:
#   control rules changelog copyright watch
#   source/format source/options
#   patches/series

if [[ -n "${_CELLULOID_PACKAGING_SH:-}" ]]; then return 0; fi
_CELLULOID_PACKAGING_SH=1

# Debian revision format: <rev>~<suite>
#
# The "~<suite>" suffix sorts *below* a plain "<rev>", so a genuine Debian
# archive upload of the same upstream version always wins over a locally
# produced package. That is the correct precedence for a rebuild.
debian_revision() {
  local suite=$1 rev=${2:-1}
  printf '%s~%s' "$rev" "$suite"
}

debian_version() {
  local upstream=$1 suite=$2 rev=${3:-1}
  printf '%s-%s' "$upstream" "$(debian_revision "$suite" "$rev")"
}

# generate_debian_dir <dest> <upstream_version> <suite> <maintainer>
generate_debian_dir() {
  local dest=$1 upstream=$2 suite=$3 maintainer=$4
  local src
  src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../packaging" && pwd) || return 1

  mkdir -p "$dest/debian/source" "$dest/debian/patches"

  _subst "$src/control"   "$dest/debian/control"   "$upstream" "$suite" "$maintainer" || return 1
  _subst "$src/changelog" "$dest/debian/changelog" "$upstream" "$suite" "$maintainer" || return 1
  _subst "$src/copyright" "$dest/debian/copyright" "$upstream" "$suite" "$maintainer" || return 1

  # rules must stay executable
  install -m 0755 "$src/rules" "$dest/debian/rules" || return 1

  # watched upstream releases
  install -m 0644 "$src/watch" "$dest/debian/watch" || return 1

  # quilt source format and its options
  install -m 0644 "$src/source/format"  "$dest/debian/source/format"  || return 1
  install -m 0644 "$src/source/options" "$dest/debian/source/options" || return 1

  # When the private-prefix backports are in use, the binary links GTK and
  # libadwaita from /opt/gtk420. Those libraries have no shlibs database entry,
  # so their package dependencies must be declared explicitly: one in
  # debian/shlibs.local for dpkg-shlibdeps, one appended to Depends. Without
  # both, dh_shlibdeps aborts with "no dependency information found".
  if [[ "${BACKPORTS_AVAILABLE:-0}" == "1" ]]; then
    cat > "$dest/debian/shlibs.local" <<'SL'
libgtk-4 1 libgtk-4-1-backport (>= 4.20)
libadwaita-1 0 libadwaita-1-0-backport (>= 1.8)
SL
    chmod 0644 "$dest/debian/shlibs.local"

    # Append the backport packages to the binary's Depends list.
    sed -i 's|^         ${shlibs:Depends},$|         ${shlibs:Depends},\n         libgtk-4-1-backport,\n         libadwaita-1-0-backport,|' \
      "$dest/debian/control"
  fi

  # empty patch series, so patches can be added later without a format change
  install -m 0644 "$src/patches/series" "$dest/debian/patches/series" || return 1

  # debhelper compat level lives in debhelper-compat (= 13) in Build-Depends;
  # a debian/compat file must NOT also exist or dpkg-buildpackage errors out.
  rm -f "$dest/debian/compat"
}

# _subst <template> <output> <upstream> <suite> <maintainer>
_subst() {
  local tmpl=$1 out=$2 upstream=$3 suite=$4 maintainer=$5
  local dversion dist
  dversion=$(debian_version "$upstream" "$suite")
  dist=$(suite_setting "$suite" distribution)

  sed \
    -e "s|@UPSTREAM_VERSION@|${upstream}|g" \
    -e "s|@DEBIAN_VERSION@|${dversion}|g" \
    -e "s|@DEBIAN_REVISION@|$(debian_revision "$suite")|g" \
    -e "s|@SUITE@|${suite}|g" \
    -e "s|@DISTRIBUTION@|${dist}|g" \
    -e "s|@MAINTAINER@|${maintainer}|g" \
    -e "s|@DATE@|$(date -R)|g" \
    "$tmpl" > "$out" || return 1
  chmod 0644 "$out"
}
