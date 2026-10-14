#!/bin/sh
# Safe CHR legacy-BIOS recovery for the TEST VM mikrotik-1 (ESXi-188, VMID 7).
# Keeps original template and the existing 10 GiB VMDK unchanged.
# Run: sh repair-mikrotik-esxi-188.sh check
#      sh repair-mikrotik-esxi-188.sh apply
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}
export PATH

MODE=${1:-check}
VMID=7
VMX=/vmfs/volumes/DISK1-raid1/mikrotik-1/mikrotik-1/mikrotik-1.vmx
WORK=/vmfs/volumes/DISK1-raid1/mikrotik-1-legacy-bios-repair
ZIP_URL=${CHR_ZIP_URL:-https://download.mikrotik.com/routeros/7.24.5/chr-7.24.5-legacy-bios.ova.zip}
INSECURE_WGET=${INSECURE_WGET:-0}
EXPECTED_SHA256=${EXPECTED_SHA256:-}
ZIP=$WORK/chr-7.24.5-legacy-bios.ova.zip
NEW_DISK=$WORK/chr-7.24.5-legacy-bios-boot.vmdk

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }

case "$MODE" in check|apply) ;; *) fail "Use check or apply" ;; esac
[ -f "$VMX" ] || fail "VMX missing: $VMX"
vmline=$(vim-cmd vmsvc/getallvms | awk -v i="$VMID" '$1==i && $2=="mikrotik-1" {print $0;exit}')
[ -n "$vmline" ] || fail "VMID $VMID is not named mikrotik-1"
vim-cmd vmsvc/power.getstate "$VMID" | grep -q 'Powered off' || fail "Power off VMID $VMID first"

info "Target VM: $vmline"
info "Existing VMX: $VMX"
info "Proposed new disk: $NEW_DISK"
info "Download: $ZIP_URL"
grep -E '^(firmware|ide[0-9]:[0-9]|scsi[0-9]:[0-9]|sata[0-9]:[0-9])' "$VMX" || true

# Do not silently discard any additional connected drives.
connected=$(grep -E '^(ide|scsi|sata)[0-9]+:[0-9]+\.present = "TRUE"' "$VMX" | grep -v -e '^ide0:0\.present' -e '^scsi0:0\.present' || true)
[ -z "$connected" ] || fail "Additional virtual disks/controllers exist; inspect manually: $connected"

# Snapshot state must be unambiguous before changing the boot VMDK reference.
snaps=$(vim-cmd vmsvc/snapshot.get "$VMID" 2>&1) || fail 'Cannot query snapshots'
if printf '%s\n' "$snaps" | grep -Eq 'Snapshot Name|Snapshot Id|Snapshot Tree'; then
  fail 'Snapshots detected; do not rewire the boot disk until they are consolidated/reviewed'
fi

if [ "$MODE" = check ]; then
  info 'Preflight passed. Apply mode downloads the official legacy BIOS OVA and attaches a NEW VMDK.'
  info 'Use only a trusted ZIP source. Default TLS validation is enabled; opt-out is insecure.'
  exit 0
fi

[ "$INSECURE_WGET" = 0 ] || [ "$INSECURE_WGET" = 1 ] || fail 'INSECURE_WGET must be 0 or 1'
for bin in unzip tar awk grep dd sha256sum vmkfstools cp mv wget; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    fail "Missing ESXi command: $bin (prepare the OVA on a Linux workstation if needed)"
  fi
done
mkdir -p "$WORK"

if [ ! -f "$ZIP" ]; then
  info "Downloading the MikroTik CHR legacy-BIOS archive"
  if [ "$INSECURE_WGET" = 1 ]; then
    info 'WARNING: certificate validation is DISABLED for this download.'
    wget --no-check-certificate -O "$ZIP.part" "$ZIP_URL" || fail 'Download failed'
  else
    wget -O "$ZIP.part" "$ZIP_URL" || fail 'Download failed (consider fetching securely on Ubuntu instead)'
  fi
  [ -s "$ZIP.part" ] || fail 'Empty download'
  mv -f "$ZIP.part" "$ZIP"
fi

actual=$(sha256sum "$ZIP" | awk '{print $1}')
info "Archive SHA256: $actual"
if [ -n "$EXPECTED_SHA256" ]; then
  [ "$actual" = "$EXPECTED_SHA256" ] || fail 'SHA256 does not match the independent expected hash'
else
  info 'WARNING: SHA256 was recorded but NOT authenticated against a trusted expected value.'
fi

# Extract only into the dedicated repair folder (never into the VM folder).
mkdir -p "$WORK/zip" "$WORK/ova"
unzip -o "$ZIP" -d "$WORK/zip" || fail 'ZIP extraction failed'
set -- "$WORK/zip"/*.ova
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'ZIP must contain exactly one top-level OVA file'
OVA=$1
[ "${OVA##*/}" = "chr-7.24.5-legacy-bios.ova" ] || fail "Expected official legacy-BIOS OVA, found: ${OVA##*/}"

tar -tf "$OVA" > "$WORK/tar-files.txt" || fail 'Not a valid OVA/TAR'
if awk '$0 ~ /^\// || $0 ~ /^\.\.\// || $0 ~ /\/\.\.\// || $0 ~ /\/\.\.$/ || $0 == ".." {bad=1} END {exit !bad}' "$WORK/tar-files.txt"; then
  fail 'Unsafe OVA archive entry'
fi
(cd "$WORK/ova" && tar -xf "$OVA") || fail 'OVA extraction failed'
set -- "$WORK/ova"/*.vmdk
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'OVA must contain one top-level VMDK'
OVA_DISK=$1

if [ -e "$NEW_DISK" ]; then
  vmkfstools -e "$NEW_DISK" || fail 'Previously generated repair VMDK is inconsistent'
  info 'Reusing the already converted repair VMDK'
else
  vmkfstools -i "$OVA_DISK" "$NEW_DISK" -d thin || fail 'Conversion failed'
  vmkfstools -e "$NEW_DISK" || fail 'New boot disk failed chain validation'
fi

BACKUP="$VMX.before-legacy-boot-$(date -u +%Y%m%dT%H%M%SZ)"
[ ! -e "$BACKUP" ] || fail "Backup already exists: $BACKUP"
cp -p "$VMX" "$BACKUP" || fail 'Cannot back up VMX'
info "Original VMX backup: $BACKUP"

TEMP="$VMX.repair.$$"
trap 'rm -f "$TEMP"' 0
awk -v disk="$NEW_DISK" '
  /^firmware[[:space:]]*=/ {next}
  /^ide0:0\./ {next}
  /^scsi0([.:]|[[:space:]]*=)/ {next}
  {print}
  END {
    print "firmware = \"bios\""
    print "ide0:0.present = \"TRUE\""
    print "ide0:0.fileName = \"" disk "\""
  }
' "$VMX" > "$TEMP" || fail 'Failed to generate repaired VMX'
grep -q '^firmware = "bios"$' "$TEMP" || fail 'Firmware validation failed'
grep -q '^ide0:0.present = "TRUE"$' "$TEMP" || fail 'IDE validation failed'
info 'Applying BIOS + IDE with a fresh legacy-BIOS VMDK'
cp "$TEMP" "$VMX" || fail 'Cannot update VMX'
if ! vim-cmd vmsvc/reload "$VMID"; then
  info 'VM reload failed; restoring the backed up VMX'
  cp "$BACKUP" "$VMX"
  vim-cmd vmsvc/reload "$VMID" || true
  fail 'Unable to reload VM configuration'
fi
info 'Prepared successfully. Start VM manually using: vim-cmd vmsvc/power.on 7'
info "Original 10GB VMDK untouched; original template untouched. VMX backup: $BACKUP"