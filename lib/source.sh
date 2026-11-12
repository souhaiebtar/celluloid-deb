#!/usr/bin/env bash
# Source acquisition: download an upstream release tarball and verify it against
# the maintainer's GPG signature before it is ever handed to the compiler.
#
# Verification is not optional decoration. A tampered tarball would end up as a
# root-installed binary, so a bad or missing signature aborts the build unless
# the caller explicitly opted out.

if [[ -n "${_CELLULOID_SOURCE_SH:-}" ]]; then return 0; fi
_CELLULOID_SOURCE_SH=1

# gnupg_home <workdir> — an isolated keyring, so we never touch the user's ~/.gnupg.
gnupg_home() {
  local dir=$1/.gnupg
  mkdir -p "$dir"
  chmod 0700 "$dir"
  printf '%s' "$dir"
}

# import_upstream_key <gnupghome>
import_upstream_key() {
  local home=$1 keyfile rc=0
  keyfile=$(mktemp "${TMPDIR:-/tmp}/celluloid-key.XXXXXX")

  step "importing upstream signing key" >&2
  curl -fsSL --max-time 30 -o "$keyfile" "$UPSTREAM_KEY_URL" || {
    rm -f "$keyfile"
    warn "could not download upstream key from $UPSTREAM_KEY_URL" >&2
    return 1
  }

  GNUPGHOME=$home gpg --batch --quiet --import "$keyfile" 2>/dev/null || rc=$?
  rm -f "$keyfile"
  return $rc
}

# verify_tarball <tarball> <signature> <gnupghome> <expected_fingerprint>
#
# Returns 0 only on a good signature made by the expected key.
verify_tarball() {
  local tarball=$1 sig=$2 home=$3 expected=${4:-}
  local errtxt status

  [[ -f "$sig" ]] || { warn "no signature file for $(basename "$tarball")" >&2; return 1; }

  errtxt=$(GNUPGHOME=$home gpg --batch --status-fd 1 --verify "$sig" "$tarball" 2>/dev/null)
  status=$(printf '%s' "$errtxt" | grep '^\[GNUPG:\]' || true)

  if ! printf '%s' "$status" | grep -q 'GOODSIG'; then
    warn "signature check FAILED for $(basename "$tarball")" >&2
    printf '%s\n' "$errtxt" | sed 's/^/    /' >&2
    return 1
  fi

  # Confirm the signature was made by the key we expect, not merely by some key
  # that happens to be in the keyring. VALIDSIG carries the primary key
  # fingerprint of the signer as its second field.
  if [[ -n "$expected" ]]; then
    local signer
    signer=$(printf '%s' "$status" \
             | awk '$2=="VALIDSIG"{print $3; exit}')
    if [[ -z "$signer" ]]; then
      warn "could not determine the signing key for $(basename "$tarball")" >&2
      return 1
    fi
    if [[ "${signer^^}" != "${expected^^}" ]]; then
      warn "tarball signed by unexpected key $signer" >&2
      warn "expected $expected" >&2
      return 1
    fi
  fi

  return 0
}

# fetch_source <tarball_url> <sig_url> <destdir> <workdir> <verify:0|1> <fingerprint>
#
# Downloads into <destdir> and prints the resulting tarball path on stdout.
fetch_source() {
  local tar_url=$1 sig_url=$2 dest=$3 work=$4 do_verify=$5 fp=${6:-}
  local tarball sigfile home

  mkdir -p "$dest"
  tarball="$dest/$(basename "${tar_url%%\?*}")"
  sigfile="${tarball}.asc"

  if [[ -f "$tarball" ]]; then
    step "using cached $(basename "$tarball")" >&2
  else
    step "downloading $(basename "$tarball")" >&2
    # --progress-bar only when the user asked for streaming output; otherwise
    # keep the log readable.
    local curl_opts=(-fL --retry 3 --retry-delay 2 --max-time 300)
    if verbose; then curl_opts+=(--progress-bar); else curl_opts+=(-sS); fi
    curl "${curl_opts[@]}" -o "$tarball.part" "$tar_url" >&2 || {
      rm -f "$tarball.part"
      return 1
    }
    mv -f "$tarball.part" "$tarball"
  fi

  if [[ "$do_verify" == "1" ]]; then
    if [[ -n "$sig_url" ]]; then
      if [[ ! -f "$sigfile" ]]; then
        curl -fsSL --retry 3 --max-time 60 -o "$sigfile" "$sig_url" >&2 || {
          warn "could not download signature; refusing to build unverified source" >&2
          return 1
        }
      fi
      home=$(gnupg_home "$work")
      import_upstream_key "$home" >/dev/null || { warn "key import failed" >&2; return 1; }
      verify_tarball "$tarball" "$sigfile" "$home" "$fp" || return 1
      ok "signature verified for $(basename "$tarball")" >&2
    else
      warn "upstream publishes no signature for this release; skipping check" >&2
    fi
  else
    warn "source verification disabled by request" >&2
  fi

  printf '%s' "$tarball"
}

# extract_source <tarball> <destdir>
# Prints the extracted top-level directory.
extract_source() {
  local tarball=$1 dest=$2 top
  mkdir -p "$dest"
  tar -xf "$tarball" -C "$dest" || return 1
  top=$(find "$dest" -mindepth 1 -maxdepth 1 -type d -name 'celluloid-*' \
        -printf '%p\n' | head -1)
  [[ -n "$top" ]] || return 1
  printf '%s' "$top"
}
