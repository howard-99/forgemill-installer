#!/bin/sh
# ForgeMill ESXi CHR recovery v2: pre-extracted legacy BIOS OVA, no unzip.
# Keeps original template and the existing 10 GiB VMDK unchanged.
# Run: sh repair-mikrotik-esxi-188.sh check
#      OVA_SHA256=<expected SHA256 from the Ubuntu image server> sh repair-mikrotik-esxi-188.sh apply
set -eu
PATH=/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}
export PATH

MODE=${1:-check}
VMID=7
VMX=/vmfs/volumes/DISK1-raid1/mikrotik-1/mikrotik-1/mikrotik-1.vmx
WORK=/vmfs/volumes/DISK1-raid1/mikrotik-1-legacy-bios-repair
OVA_URL=${OVA_URL:-http://172.31.31.183/iso/chr-7.24.5-legacy-bios.ova}
OVA_SHA256=${OVA_SHA256:-}
OVA=$WORK/chr-7.24.5-legacy-bios.ova
NEW_DISK=$WORK/chr-7.24.5-legacy-bios-boot.vmdk

fail() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "INFO: $*"; }
find_exec() {
  name=$1
  for dir in /bin /sbin /usr/bin /usr/sbin; do
    [ -x "$dir/$name" ] && return 0
  done
  return 1
}

case "$MODE" in check|apply) ;; *) fail "Use check or apply" ;; esac
# ESXi BusyBox may not support 'command -v'; verify executables by path.
for bin in vim-cmd vmkfstools tar awk grep sha256sum cp mv wget mkdir rm date; do
  find_exec "$bin" || fail "Missing ESXi executable: $bin"
done
[ -f "$VMX" ] || fail "VMX missing: $VMX"
vmkfstools -e /vmfs/volumes/DISK1-raid1/mikrotik-1/mikrotik-1.vmdk || fail "Original VMDK invalid or locked; power off VM first"
vmline=$(vim-cmd vmsvc/getallvms | awk -v i="$VMID" '$1==i && $2=="mikrotik-1" {print $0;exit}')
[ -n "$vmline" ] || fail "VMID $VMID is not named mikrotik-1"
vim-cmd vmsvc/power.getstate "$VMID" | grep -q 'Powered off' || fail "Power off VMID $VMID first"

info "Target VM: $vmline"
info "Existing VMX: $VMX"
info "Proposed new disk: $NEW_DISK"
info "Source OVA: $OVA_URL"
info "Expected OVA SHA256: ${OVA_SHA256:-NOT SET}"
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
  info 'Preflight PASS: ESXi tools available; VM is powered off.'
  info 'Supply an unzipped official legacy BIOS .ova via the existing HTTP image server.'
  info 'Apply requires OVA_SHA256 computed independently on the Ubuntu server.'
  exit 0
fi

case "$OVA_SHA256" in ''|*[!0123456789abcdefABCDEF]*) fail 'OVA_SHA256 must be a 64-character hexadecimal checksum' ;; esac
[ "${#OVA_SHA256}" -eq 64 ] || fail 'OVA_SHA256 must have exactly 64 hex characters'
case "$OVA_URL" in http://*|https://*) ;; *) fail "OVA_URL must be an http(s) URL" ;; esac

[ ! -e "$NEW_DISK" ] || fail "New boot disk already exists: $NEW_DISK; inspect before retrying"
[ ! -e "${NEW_DISK%.vmdk}-flat.vmdk" ] || fail 'New flat disk already exists; inspect before retrying'
mkdir -p "$WORK"
if [ -e "$OVA" ]; then
  info 'Reusing previously downloaded OVA only after full SHA256 verification.'
else
  info "Downloading unzipped OVA from $OVA_URL"
  wget -O "$OVA.part" "$OVA_URL" || fail 'OVA download failed; prepare .ova on Ubuntu server'
  [ -s "$OVA.part" ] || fail 'Downloaded OVA is empty'
  mv -f "$OVA.part" "$OVA"
fi
actual=$(sha256sum "$OVA" | awk '{print $1}')
info "Downloaded OVA SHA256: $actual"
[ "$actual" = "$OVA_SHA256" ] || fail 'SHA256 mismatch: refusing to import untrusted or corrupted OVA'

# Extract only into a dedicated repair folder; never overwrite the original VMDK.
[ ! -e "$WORK/ova" ] || fail 'Existing extraction folder found; inspect it before retrying'
mkdir "$WORK/ova"
tar -tf "$OVA" > "$WORK/tar-files.txt" || fail 'Not a valid OVA/TAR'
if tar -tvf "$OVA" | awk '{t=substr($1,1,1); if (t=="l" || t=="h") bad=1} END {exit !bad}'; then
  fail 'OVA contains archive links, refusing extraction'
fi
if awk '$0 ~ /^\// || $0 ~ /^\.\.\// || $0 ~ /\/\.\.\// || $0 ~ /\/\.\.$/ || $0 == ".." {bad=1} END {exit !bad}' "$WORK/tar-files.txt"; then
  fail 'Unsafe OVA archive entry'
fi
(cd "$WORK/ova" && tar -xf "$OVA") || fail 'OVA extraction failed'
set -- "$WORK/ova"/*.vmdk
[ "$#" -eq 1 ] && [ -f "$1" ] || fail 'OVA must contain one top-level VMDK'
OVA_DISK=$1

vmkfstools -i "$OVA_DISK" "$NEW_DISK" -d thin || fail 'VMDK conversion failed'
vmkfstools -e "$NEW_DISK" || fail 'New boot disk failed chain validation'

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
cp -f "$TEMP" "$VMX" || fail 'Cannot update VMX'
if ! vim-cmd vmsvc/reload "$VMID"; then
  info 'VM reload failed; restoring the backed up VMX'
  cp -f "$BACKUP" "$VMX"
  vim-cmd vmsvc/reload "$VMID" || true
  fail 'Unable to reload VM configuration'
fi
info 'Prepared successfully. Start VM manually using: vim-cmd vmsvc/power.on 7'
info "Original 10GB VMDK untouched; original template untouched. VMX backup: $BACKUP"