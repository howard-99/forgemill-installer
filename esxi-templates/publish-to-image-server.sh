#!/usr/bin/env bash
# Publish the ESXi BusyBox installer over the same LAN HTTP image server as OVAs.
# Run on the trusted Linux/Proxmox image server (172.31.31.183), NOT on ESXi.
# Does not change VMs, hypervisor software, web-server configuration or OVAs.
set -Eeuo pipefail
umask 022
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

BASE_DIR=${IMAGE_DIRECTORY:-/var/lib/vz/template/iso}
REF=${FORGEMILL_IMPORT_REF:-main}
FILENAME=forgemill-esxi-import.sh

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "[ForgeMill ESXi] $*"; }

for exe in curl sha256sum sh mktemp mv chmod; do
  command -v "$exe" >/dev/null 2>&1 || die "Missing prerequisite: $exe"
done
[ -d "$BASE_DIR" ] || die "Image directory not found: $BASE_DIR"
[ -w "$BASE_DIR" ] || die "Image directory not writable: $BASE_DIR"
[ ! -L "$BASE_DIR/$FILENAME" ] || die "Refusing symlink at destination: $BASE_DIR/$FILENAME"

# Allow the default moving main branch or a pinned 40-hex commit only.
case "$REF" in
  main) ;;
  *)
    if ! printf '%s\n' "$REF" | grep -Eq '^[0-9a-fA-F]{40}$'; then
      die 'FORGEMILL_IMPORT_REF must be main or a full 40-hex Git commit'
    fi
    ;;
esac

STAGE=$(mktemp "$BASE_DIR/.forgemill-esxi-import.XXXXXXXX")
cleanup() { rm -f -- "$STAGE"; }
trap cleanup EXIT

URL="https://raw.githubusercontent.com/howard-99/forgemill-installer/$REF/esxi-templates/import.sh"
info "Fetching $URL with verified HTTPS on the image server"
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
  --retry 2 --connect-timeout 15 --max-time 120 \
  "$URL" --output "$STAGE" || die 'GitHub download failed on image server; existing published script is untouched'

[ -s "$STAGE" ] || die 'Downloaded importer is empty'
head -n 1 "$STAGE" | grep -qx '#!/bin/sh' || die 'Downloaded file is not the expected POSIX shell script'
sh -n "$STAGE" || die 'Importer syntax validation failed; old published file untouched'

HASH=$(sha256sum "$STAGE" | awk '{print $1}')
if [ -n "${EXPECTED_SCRIPT_SHA256:-}" ]; then
  EXPECTED=$(printf '%s' "$EXPECTED_SCRIPT_SHA256" | tr 'A-F' 'a-f')
  [ "${#EXPECTED}" -eq 64 ] || die 'EXPECTED_SCRIPT_SHA256 must be a SHA-256 digest (64 hex characters)'
  case "$EXPECTED" in *[!0-9a-f]*) die 'Invalid EXPECTED_SCRIPT_SHA256' ;; esac
  [ "$HASH" = "$EXPECTED" ] || die "SHA-256 mismatch. Downloaded=$HASH"
fi

chmod 0644 "$STAGE" || die 'Cannot set web-readable permissions'
mv -f -- "$STAGE" "$BASE_DIR/$FILENAME" || die 'Atomic publish failed'
trap - EXIT

info "PUBLISHED: $BASE_DIR/$FILENAME"
info "SHA256: $HASH"
info "Expected LAN URL: http://172.31.31.183/iso/$FILENAME"
info 'Verify URL with curl -I from this host, and compare this checksum from ESXi.'
info 'The installer must be refreshed here when GitHub main changes.'
