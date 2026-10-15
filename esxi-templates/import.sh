#!/bin/sh
# ForgeMill ESXi Main Template Importer — v2.0
# ESXi 7.x / 8.x BusyBox/POSIX sh; no external VM management workstation required.
# Usage: sh forgemill-esxi-import.sh [all|ubuntu|rocky|mikrotik|check|status]
# Imported VMs remain powered OFF. Nothing registered or stored previously is deleted.
set -eu

# ESXi shells can have a reduced command search path when running scripts.
# Prepend standard host locations without relying on the invoking SSH session.
PATH="/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}"
export PATH

MODE=${1:-all}
BASE_URL=${BASE_URL:-http://172.31.31.183/iso}
PORTGROUP=${PORTGROUP:-VM Network}
DATASTORE=${DATASTORE:-}
MIN_FREE_GB=${MIN_FREE_GB:-12}
KEEP_SOURCE=${KEEP_SOURCE:-0}
KEEP_FAILED=${KEEP_FAILED:-0}
# Opt-in only: bypass TLS certificate validation for HTTPS OVA sources.
WGET_NO_CHECK_CERT=${WGET_NO_CHECK_CERT:-0}
HW_VERSION=17

say() { printf '\n===== %s =====\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

case "$MODE" in
  all|ubuntu|rocky|rockyvmware|chr|mikrotik|chr7237|check|status) ;;
  -h|--help|help)
    cat <<'HELP'
Usage: sh forgemill-esxi-import.sh [MODE]
  all       Import EXACTLY THREE: Ubuntu 24.04, Rocky 9.8 VMware, CHR 7.23.7
  ubuntu    Import Ubuntu 24.04 only
  rocky     Import tested Rocky 9.8 VMware OVA only (alias rockyvmware)
  mikrotik  Import CHR 7.23.7 Legacy BIOS only (aliases chr, chr7237)
  check     Display datastores/VM networks and selected target datastore
  status    Display registered virtual machines; no changes

Optional environment variables:
  DATASTORE='DISK1-raid1'  Prefer this specific mounted VMFS datastore
  PORTGROUP='VM Network'  Exact ESXi standard VM port-group name
  BASE_URL='http://172.31.31.183/iso'  OVA files source
  MIN_FREE_GB=12         Minimum free storage required before import
  KEEP_SOURCE=1          Preserve downloaded/extracted OVA files after success
  KEEP_FAILED=1          Preserve failed staging directory for diagnostics
  UBUNTU_SHA256=...      Recommended trusted OVA SHA256 for Ubuntu 24.04
  CHR_7237_SHA256=...    Recommended trusted OVA SHA256 for CHR 7.23.7
  ROCKY_VMWARE_SHA256=... Override pinned Rocky 9.8 SHA256 if rebuilt
  WGET_NO_CHECK_CERT=1   Bypass TLS certificate validation for HTTPS OVA only (insecure)

Safety: never overwrite existing templates, delete original VM disks, change
firewall rules, or power on imported images. Use a dedicated VM network.
Standalone ESXi has no native vCenter template objects: these are tagged,
powered-off VM sources for ForgeMill cloning.
WARNING: An unpatched ForgeMill standalone-ESXi fallback can recreate IDE
boot disks as SCSI and lose CHR keyboard settings. Import alone does not
repair ForgeMill's cloning code; test a CHR deployment before production.
HELP
    exit 0 ;;
  *) fail "Unknown mode '$MODE'. Use all, ubuntu, rocky, mikrotik, chr, chr7237, rockyvmware, check or status." ;;
esac

# ESXi 7 may expose commands in different directories and some BusyBox
# environments make `command -v` an unreliable prerequisite by itself.
find_exec() {
  executable=$1
  for directory in /bin /sbin /usr/bin /usr/sbin; do
    if [ -x "$directory/$executable" ]; then
      printf '%s\n' "$directory/$executable"
      return 0
    fi
  done
  # Some ESXi 7 shells lack the POSIX `command` builtin.
  # Do not use `command -v`: VMware utilities are normally in these dirs.
  return 1
}

if ESXCLI_EXEC=$(find_exec esxcli); then
  :
elif ESXCLI_EXEC=$(find_exec localcli); then
  warn 'esxcli not found; using localcli for read-only host inventory.'
else
  fail "Neither esxcli nor localcli found. PATH=$PATH. Check: ls -l /bin/esxcli /usr/bin/esxcli /sbin/esxcli"
fi

# All uses below are read-only inventory/version checks; the import operations
# continue to use vim-cmd and vmkfstools.
esxcli() { "$ESXCLI_EXEC" "$@"; }

for required in vim-cmd awk grep sed tar wget vmkfstools mkdir mv rm cp rmdir cat; do
  find_exec "$required" >/dev/null 2>&1 || fail "Missing required executable: $required (PATH=$PATH)"
done

ESXI_VER=$(esxcli system version get) || fail "Cannot read ESXi version using $ESXCLI_EXEC"
case "$ESXI_VER" in
  *"Version: 7."*|*"Version: 8."*) ;;
  *) fail "This importer targets ESXi 7.x/8.x; detected: $ESXI_VER" ;;
esac
info "ESXi host version: $(printf '%s\n' "$ESXI_VER" | awk '/Version:/ {print $2;exit}')"

if [ "$MODE" = status ]; then
  say 'VM inventory and ForgeMill main-template sources'
  inventory=$(vim-cmd vmsvc/getallvms) || fail 'Cannot list ESXi VMs'
  printf '%s\n' "$inventory"
  for name in Template-Ubuntu-24.04 Template-Rocky-9.8 Template-MikroTik-CHR-7.23.7; do
    id=$(printf '%s\n' "$inventory" | awk -v n="$name" '$1 ~ /^[0-9]+$/ && $2==n {print $1; exit}')
    if [ -z "$id" ]; then
      info "NOT FOUND: $name"
      continue
    fi
    state=$(vim-cmd vmsvc/power.getstate "$id") || fail "Cannot query VMID $id"
    if printf '%s\n' "$state" | grep -q 'Powered off'; then
      info "FOUND: $name (VMID $id, powered off; verify VMX hardware before deploying)"
    else
      warn "NOT READY: $name (VMID $id, not powered off)"
    fi
  done
  info 'Standalone ESXi registers these as VMs, not native vCenter template objects.'
  exit 0
fi

# Mount point | free bytes. All fields after mount/name are fixed-width columns;
# using fields from the right tolerates spaces in VMware volume names.
mount_records() {
  esxcli storage filesystem list | awk '
    NF>=7 && $(NF-3)=="true" && $(NF-2) ~ /^VMFS-[0-9]+$/ && $NF ~ /^[0-9]+$/ {
      printf "%s|%.0f\n", $1, $NF+0
    }'
}

# Return canonical path (also resolves /vmfs/volumes/<friendly datastore name>).
real_dir() { (cd "$1" 2>/dev/null && pwd -P); }

want_path=''
if [ -n "$DATASTORE" ]; then
  case "$DATASTORE" in
    /vmfs/volumes/*) want_path=$(real_dir "$DATASTORE") || fail "Missing datastore: $DATASTORE" ;;
    *) want_path=$(real_dir "/vmfs/volumes/$DATASTORE") || fail "Missing datastore: $DATASTORE" ;;
  esac
fi

select_datastore() {
  case "$MIN_FREE_GB" in ''|*[!0-9]*) fail "MIN_FREE_GB must be a positive integer" ;; esac
  # Do not use shell arithmetic for byte sizes: ESXi BusyBox builds can
  # perform 32-bit integer math even on a 64-bit host. 12 GiB overflows.
  # The comparisons below run in awk floating-point arithmetic instead.
  RECORDS=$(mount_records)
  [ -n "$RECORDS" ] || fail 'No mounted local VMFS datastores were detected.'
  SELECTED=''
  SELECTED_BYTES=0
  FOUND_OVERRIDE=0

  while IFS='|' read -r path freebytes; do
    [ -n "$path" ] || continue
    canonical=$(real_dir "$path") || continue
    if [ -n "$want_path" ]; then
      [ "$canonical" = "$want_path" ] || continue
      FOUND_OVERRIDE=1
    fi
    if ! awk -v free="$freebytes" -v min_gib="$MIN_FREE_GB" '
      BEGIN {exit !((free + 0) >= (min_gib + 0) * 1073741824)}
    '; then
      warn "Insufficient free space: $path (requires ${MIN_FREE_GB} GiB)"
      continue
    fi
    # Probe writability rather than relying on mount flags alone.
    probe="$path/.fm-writable-$$"
    if ! mkdir "$probe" 2>/dev/null; then
      warn "Cannot write to VMFS datastore $path"
      continue
    fi
    rmdir "$probe" || fail "Cannot clean up writable probe at $probe"
    if [ -z "$SELECTED" ] || awk -v candidate="$freebytes" -v selected="$SELECTED_BYTES" '
      BEGIN {exit !((candidate + 0) > (selected + 0))}
    '; then
      SELECTED="$path"
      SELECTED_BYTES="$freebytes"
    fi
  done <<EOF_MOUNTS
$RECORDS
EOF_MOUNTS

  if [ -n "$DATASTORE" ] && [ "$FOUND_OVERRIDE" -ne 1 ]; then
    fail "DATASTORE='$DATASTORE' is not a mounted local VMFS datastore"
  fi
  [ -n "$SELECTED" ] || fail "No writable VMFS datastore with at least ${MIN_FREE_GB} GiB free. Use DATASTORE=... or lower MIN_FREE_GB only if safe."
  DS="$SELECTED"
  info "Selected VMFS datastore: $DS"
  free_gib=$(awk -v bytes="$SELECTED_BYTES" 'BEGIN {printf "%.1f", (bytes + 0) / 1073741824}')
  info "Free space before import: $free_gib GiB"
}

validate_portgroup() {
  # Names may contain spaces; split the column at two-or-more whitespace chars.
  esxcli network vswitch standard portgroup list | awk -v pg="$PORTGROUP" '
    NR>2 {
      s=$0
      sub(/[ \t][ \t]+.*/, "", s)
      sub(/^[ \t]+/, "", s)
      sub(/[ \t]+$/, "", s)
      if (s==pg) found=1
    }
    END {exit !found}
  ' || fail "Standard port group '$PORTGROUP' not found. Set PORTGROUP to an exact name from 'esxcli network vswitch standard portgroup list'."
  info "VM port group: $PORTGROUP"
}

say 'Host storage inventory'
esxcli storage filesystem list
say 'VM network inventory'
esxcli network vswitch standard portgroup list
select_datastore
validate_portgroup
case "$WGET_NO_CHECK_CERT" in 0|1) ;; *) fail 'WGET_NO_CHECK_CERT must be 0 or 1' ;; esac

if [ "$MODE" = check ]; then
  say 'Preflight PASS'
  info "OVAs under $BASE_URL: ubuntu-24.04-server-cloudimg-amd64.ova, rocky-9.8-forgemill-vmware.ova, chr-7.23.7-legacy-bios.ova"
  info 'No image files downloaded or boot-tested in check mode.'
  info 'No VMs were changed.'
  exit 0
fi

# List all registered VMs only; no changes are made to ones already present.
registered_id() {
  name=$1
  vim-cmd vmsvc/getallvms 2>&1 | awk -v n="$name" '
    $1 ~ /^[0-9]+$/ && $2==n {print $1; exit}
  '
}

# A directory with the requested name, even if currently unregistered, is
# protected on every mounted VMFS datastore (not just the selected one).
existing_directory() {
  name=$1
  dirs=$(mount_records)
  while IFS='|' read -r mountpoint freebytes; do
    [ -n "$mountpoint" ] || continue
    if [ -e "$mountpoint/$name" ]; then
      printf '%s\n' "$mountpoint/$name"
      return 0
    fi
  done <<EOF_CHECK
$dirs
EOF_CHECK
  return 1
}

# Read resource allocation entries from common VMware/OVF 1.x descriptors.
# VMDK import supports one boot disk and SCSI or IDE controllers.
parse_ovf_hardware() {
  ovf=$1
  output=$2
  awk '
    /<Item([[:space:]>])/ { inside=1; type=""; subtype=""; iid=""; parent="" }
    inside && /ResourceType>/ {
      v=$0; sub(/^.*<[[:alnum:]_:-]*ResourceType>/,"",v); sub(/<.*/,"",v); type=v
    }
    inside && /ResourceSubType>/ {
      v=$0; sub(/^.*<[[:alnum:]_:-]*ResourceSubType>/,"",v); sub(/<.*/,"",v); subtype=v
    }
    inside && /InstanceID>/ {
      v=$0; sub(/^.*<[[:alnum:]_:-]*InstanceID>/,"",v); sub(/<.*/,"",v); iid=v
    }
    inside && /<[^>]*Parent>/ {
      v=$0; sub(/^.*<[[:alnum:]_:-]*Parent>/,"",v); sub(/<.*/,"",v); parent=v
    }
    inside && /<\/Item>/ {
      if (type=="5" || type=="6") print "controller|" iid "|" type "|" subtype
      if (type=="17") print "disk|" parent
      inside=0
    }
  ' "$ovf" > "$output"
}

# Verify checksums supplied by an OVA's .mf file. SHA1, SHA256, SHA512.
verify_manifest() {
  src=$1
  set -- "$src"/*.mf
  if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    warn 'No single OVF manifest found; cannot verify internal image hashes.'
    return 0
  fi
  manifest=$1
  verified=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      SHA1\(*|SHA256\(*|SHA512\(*) ;;
      ''|\#*) continue ;;
      *) warn "Unrecognized manifest entry: $line"; continue ;;
    esac
    alg=${line%%(*}
    filename=${line#*(}
    filename=${filename%%)*}
    expected=${line#*=}
    expected=$(printf '%s\n' "$expected" | awk '{gsub(/[[:space:]]/,""); print tolower($0)}')
    case "$filename" in
      ''|/*|../*|*/../*|*'/..'|*'\\'*) fail 'Unsafe manifest filename' ;;
    esac
    [ -f "$src/$filename" ] || fail "Manifest file absent: $filename"
    case "$expected" in ''|*[!0-9a-f]*) fail "Invalid manifest checksum for $filename" ;; esac
    case "$alg" in
      SHA1) checksum_program=sha1sum ;;
      SHA256) checksum_program=sha256sum ;;
      SHA512) checksum_program=sha512sum ;;
    esac
    find_exec "$checksum_program" >/dev/null 2>&1 || fail "Cannot verify manifest without $checksum_program"
    actual=$("$checksum_program" "$src/$filename" | awk '{print tolower($1)}')
    [ "$actual" = "$expected" ] || fail "OVA checksum mismatch: $filename"
    verified=$((verified + 1))
  done < "$manifest"
  [ "$verified" -gt 0 ] || warn 'Manifest contains no supported SHA checksums.'
  info "Verified $verified manifest checksums"
}

ACTIVE_STAGE=''
# Keep HTTPS certificate validation on by default. Some ESXi BusyBox wget
# builds cannot validate the certificate chain; only opt out explicitly.
download_ova() {
  target_file=$1
  source_url=$2
  case "$source_url" in
    https://*)
      if [ "$WGET_NO_CHECK_CERT" = 1 ]; then
        wget --no-check-certificate -O "$target_file" "$source_url"
        return $?
      fi
      ;;
  esac
  wget -O "$target_file" "$source_url"
}
cleanup_stage() {
  exitcode=$?
  trap - 0 HUP INT TERM
  if [ -n "$ACTIVE_STAGE" ] && [ -d "$ACTIVE_STAGE" ]; then
    if [ "$KEEP_FAILED" = 1 ]; then
      warn "Failure diagnostics preserved: $ACTIVE_STAGE"
    else
      warn "Removing incomplete staging files: $ACTIVE_STAGE"
      rm -rf "$ACTIVE_STAGE"
    fi
  fi
  exit "$exitcode"
}
trap 'cleanup_stage' 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

import_image() {
  kind=$1
  IS_CHR=0
  EXPECTED_SHA256=''
  case "$kind" in
    ubuntu)
      VMNAME='Template-Ubuntu-24.04'
      LEGACY_NAMES='ubuntu-24.04-main-template ubuntu-24.04-golden'
      FILE='ubuntu-24.04-server-cloudimg-amd64.ova'
      GUEST='ubuntu64Guest'
      RAM=2048
      FW_DEFAULT=bios
      CTRL_DEFAULT='6|VirtualSCSI'
      EXPECTED_SHA256=${UBUNTU_SHA256:-}
      ;;
    chr7237)
      VMNAME='Template-MikroTik-CHR-7.23.7'
      LEGACY_NAMES='mikrotik-chr-7.23.7-main-template mikrotik-chr-7.23.7-golden'
      FILE='chr-7.23.7-legacy-bios.ova'
      GUEST='otherLinux64Guest'
      RAM=1024
      FW_DEFAULT=bios
      CTRL_DEFAULT='5|IDE'
      IS_CHR=1
      EXPECTED_SHA256=${CHR_7237_SHA256:-}
      ;;
    rockyvmware)
      VMNAME='Template-Rocky-9.8'
      LEGACY_NAMES='rocky-9.8-forgemill-main-template rocky-9.8-forgemill-golden rocky-9.8-main-template rocky-9.8-golden'
      FILE='rocky-9.8-forgemill-vmware.ova'
      GUEST='otherLinux64Guest'
      RAM=2048
      FW_DEFAULT=bios
      CTRL_DEFAULT='6|pvscsi'
      # Verified OVA from Proxmox VM 100, deployed successfully by operator.
      EXPECTED_SHA256=${ROCKY_VMWARE_SHA256:-2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33}
      ;;
  esac

  say "Import: $VMNAME"
  id=$(registered_id "$VMNAME")
  if [ -n "$id" ]; then
    state=$(vim-cmd vmsvc/power.getstate "$id") || fail "Cannot inspect existing $VMNAME (VMID $id)"
    printf '%s\n' "$state" | grep -q 'Powered off' || fail "$VMNAME already exists but is powered on (VMID $id); will not treat it as a template"
    info "SKIP: $VMNAME already registered (VMID $id), powered off. Preserving existing VM and disks."
    warn "Existing VMX settings are not replaced or validated during skip; audit controller/firmware/keyboard manually."
    return 0
  fi
  # Never silently create a renamed duplicate of an existing older source.
  for legacy_name in $LEGACY_NAMES; do
    legacy_id=$(registered_id "$legacy_name")
    if [ -n "$legacy_id" ]; then
      fail "Existing source $legacy_name (VMID $legacy_id) prevents duplicate $VMNAME. Do not rename/delete blindly: migrate explicitly after checking ForgeMill references."
    fi
    if previous=$(existing_directory "$legacy_name"); then
      fail "Older source directory exists: $previous. No duplicate imported; inspect first."
    fi
  done
  if previous=$(existing_directory "$VMNAME"); then
    fail "Directory already exists: $previous. No overwrite performed. Inspect/recover this VM manually."
  fi

  FINAL="$DS/$VMNAME"
  STAGE="$DS/.forgemill-stage-$VMNAME-$$"
  [ ! -e "$STAGE" ] || fail "Staging directory collision: $STAGE"
  mkdir "$STAGE" || fail "Cannot create $STAGE"
  ACTIVE_STAGE="$STAGE"
  SRC="$STAGE/ova-source"
  mkdir "$SRC"
  OVA="$STAGE/source.ova"
  DISK="$STAGE/$VMNAME.vmdk"
  VMX="$STAGE/$VMNAME.vmx"

  say "Downloading $BASE_URL/$FILE"
  case "$BASE_URL" in
    https://*) if [ "$WGET_NO_CHECK_CERT" = 1 ]; then warn 'HTTPS certificate verification disabled for OVA download (WGET_NO_CHECK_CERT=1)'; fi ;;
  esac
  success=0
  for attempt in 1 2 3; do
    rm -f "$OVA"
    if download_ova "$OVA" "$BASE_URL/$FILE"; then
      success=1
      break
    fi
    warn "Download attempt $attempt failed"
  done
  [ "$success" -eq 1 ] || fail "OVA download failed: $BASE_URL/$FILE"
  [ -s "$OVA" ] || fail 'Downloaded OVA is empty'
  if [ -n "$EXPECTED_SHA256" ]; then
    case "$EXPECTED_SHA256" in
      *[!0-9a-fA-F]*) fail "Expected SHA256 has non-hex characters for $VMNAME" ;;
    esac
    [ "${#EXPECTED_SHA256}" -eq 64 ] || fail "Expected SHA256 must be 64 hex characters for $VMNAME"
    find_exec sha256sum >/dev/null 2>&1 || fail 'sha256sum is required for expected OVA checksum verification'
  else
    warn "No trusted expected SHA256 provided for $VMNAME; HTTP + self-computed checksum does not authenticate the image"
  fi
  if find_exec sha256sum >/dev/null 2>&1; then
    OVA_SHA256=$(sha256sum "$OVA" | awk '{print $1}')
    info "Downloaded OVA SHA256: $OVA_SHA256"
    if [ -n "$EXPECTED_SHA256" ]; then
      expected_lower=$(printf '%s' "$EXPECTED_SHA256" | awk '{print tolower($0)}')
      [ "$OVA_SHA256" = "$expected_lower" ] || fail "OVA SHA256 mismatch for $VMNAME"
      info 'Verified OVA SHA256 against expected checksum'
    fi
  else
    OVA_SHA256='unavailable (sha256sum not installed)'
    warn 'Cannot record whole-OVA SHA256 checksum'
  fi

  tar -tf "$OVA" > "$STAGE/archive-files.txt" || fail 'OVA is not a valid TAR archive'
  # Refuse path traversal or absolute paths before running tar extraction.
  if awk '$0 ~ /^\// || $0 ~ /^\.\.\// || $0 ~ /\/\.\.\// || $0 ~ /\/\.\.$/ || $0 == ".." {bad=1} END {exit !bad}' "$STAGE/archive-files.txt"; then
    fail 'OVA contains unsafe archive path names'
  fi
  if tar -tvf "$OVA" | awk '{ c=substr($1,1,1); if (c=="l" || c=="h") bad=1 } END {exit !bad}'; then
    fail 'OVA contains symlinks or hardlinks; refusing extraction'
  fi

  say 'Extracting OVA'
  ( cd "$SRC" && tar -xf "$OVA" ) || fail 'OVA extraction failed'
  set -- "$SRC"/*.ovf
  [ "$#" -eq 1 ] && [ -f "$1" ] || fail 'Require exactly one .ovf descriptor'
  OVF=$1
  set -- "$SRC"/*.vmdk
  [ "$#" -eq 1 ] && [ -f "$1" ] || fail 'Require exactly one .vmdk disk'
  SOURCE_DISK=$1
  verify_manifest "$SRC"

  FW="$FW_DEFAULT"
  fline=$(grep -i 'key="firmware"' "$OVF" | awk 'NR==1 {print; exit}' || true)
  if [ -n "$fline" ]; then
    parsed=$(printf '%s\n' "$fline" | sed -n 's/.*value="\([^"]*\)".*/\1/p')
    if [ -n "$parsed" ]; then FW=$(printf '%s\n' "$parsed" | awk '{print tolower($0)}'); fi
  fi
  case "$FW" in
    bios) ;;
    efi|uefi) FW=efi ;;
    *) fail "Unknown OVF firmware: $FW" ;;
  esac

  parse_ovf_hardware "$OVF" "$STAGE/ovf-hardware.txt"
  parent=$(awk -F '|' '$1=="disk" {print $2; exit}' "$STAGE/ovf-hardware.txt")
  ctl=''
  if [ -n "$parent" ]; then
    ctl=$(awk -F '|' -v p="$parent" '$1=="controller" && $2==p {print $3"|"$4; exit}' "$STAGE/ovf-hardware.txt")
  fi
  if [ -z "$ctl" ]; then
    ctl=$(awk -F '|' '$1=="controller" {print $3"|"$4; exit}' "$STAGE/ovf-hardware.txt")
  fi
  [ -n "$ctl" ] || ctl=$CTRL_DEFAULT
  CTL_TYPE=${ctl%%|*}
  CTL_DESC=${ctl#*|}
  case "$CTL_TYPE" in
    5) DISK_CTRL=ide; DISK_SUB='' ;;
    6)
      DISK_CTRL=scsi
      case "$(printf '%s\n' "$CTL_DESC" | awk '{print tolower($0)}')" in
        *pvscsi*|*paravirtual*) DISK_SUB=pvscsi ;;
        *sas*|*virtualscsi*|*lsisas*|'') DISK_SUB=lsisas1068 ;;
        *lsilogic*|*parallel*) DISK_SUB=lsilogic ;;
        *) fail "Unsupported OVF SCSI controller '$CTL_DESC' (check OVF)" ;;
      esac
      ;;
    *) fail "Unsupported OVF boot controller type $CTL_TYPE ($CTL_DESC); refusing to guess" ;;
  esac
  if [ "$IS_CHR" = 1 ]; then
    [ "$FW" = bios ] || fail "$FILE requires BIOS; OVF selected '$FW'"
    [ "$DISK_CTRL" = ide ] || fail "$FILE requires IDE boot disk; OVF selected '$DISK_CTRL'"
  fi
  if [ "$kind" = rockyvmware ]; then
    [ "$FW" = bios ] || fail "$FILE requires BIOS; OVF selected '$FW'"
    [ "$DISK_CTRL" = scsi ] && [ "$DISK_SUB" = pvscsi ] || fail "$FILE requires PVSCSI boot disk; OVF selected '$DISK_CTRL ${DISK_SUB:-}'"
  fi
  if [ "$kind" = ubuntu ]; then
    # Preserve the image's declared firmware/controller; reject mismatched
    # or unknown hardware instead of silently assuming an OVF default.
    [ "$DISK_CTRL" = scsi ] || fail "$FILE requires a SCSI boot disk; OVF selected '$DISK_CTRL'"
  fi
  info "Boot setup from OVF: firmware=$FW, disk=$DISK_CTRL ${DISK_SUB:-}, network=vmxnet3"

  say 'Converting stream VMDK to native thin VMFS disk'
  vmkfstools -i "$SOURCE_DISK" "$DISK" -d thin || fail 'VMDK conversion failed'
  vmkfstools -e "$DISK" || fail 'Converted VMDK chain validation failed'

  # Write valid VMX with each setting on its own line. No interpolation of
  # untrusted descriptor text other than strictly validated controller/firmware.
  say 'Writing VMX and verifying hardware configuration'
  cat > "$VMX" <<EOF_VMX
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "$HW_VERSION"
displayName = "$VMNAME"
annotation = "ForgeMill main-template source: standalone ESXi powered-off VM; clone for deployment"
guestinfo.forgemill.role = "main-template"
guestinfo.forgemill.image = "$kind"
guestOS = "$GUEST"
numvcpus = "2"
memSize = "$RAM"
firmware = "$FW"
EOF_VMX
  if [ "$IS_CHR" = 1 ]; then
    # Tested operator workaround for CHR console keyboard (PS/2 IRQ handling).
    # Do not add a virtual USB keyboard: it was not required for this fix.
    printf '%s\n' 'keyboard.allowBothIRQs = "FALSE"' >> "$VMX"
  fi
  if [ "$DISK_CTRL" = ide ]; then
    cat >> "$VMX" <<EOF_DISK
ide0:0.present = "TRUE"
ide0:0.fileName = "$VMNAME.vmdk"
EOF_DISK
  else
    cat >> "$VMX" <<EOF_DISK
scsi0.present = "TRUE"
scsi0.virtualDev = "$DISK_SUB"
scsi0:0.present = "TRUE"
scsi0:0.fileName = "$VMNAME.vmdk"
scsi0:0.deviceType = "scsi-hardDisk"
EOF_DISK
  fi
  cat >> "$VMX" <<EOF_NIC
ethernet0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
ethernet0.networkName = "$PORTGROUP"
ethernet0.addressType = "generated"
ethernet0.startConnected = "TRUE"
disk.EnableUUID = "TRUE"
tools.syncTime = "TRUE"
EOF_NIC

  grep -qx 'guestinfo.forgemill.role = "main-template"' "$VMX" || fail 'Missing ForgeMill template marker'
  if [ "$IS_CHR" = 1 ]; then
    grep -qx 'keyboard.allowBothIRQs = "FALSE"' "$VMX" || fail 'Missing CHR keyboard fix'
    grep -qx 'ide0:0.present = "TRUE"' "$VMX" || fail 'Missing CHR IDE boot disk'
    grep -qx 'firmware = "bios"' "$VMX" || fail 'Missing CHR legacy BIOS firmware'
  fi
  grep -qx "firmware = \"$FW\"" "$VMX" || fail 'Malformed firmware line in VMX'
  grep -qx 'ethernet0.startConnected = "TRUE"' "$VMX" || fail 'Malformed ethernet setting'
  grep -qx 'disk.EnableUUID = "TRUE"' "$VMX" || fail 'Malformed disk UUID setting'
  if [ "$DISK_CTRL" = scsi ]; then
    grep -qx 'scsi0:0.present = "TRUE"' "$VMX" || fail 'Malformed SCSI disk setting'
  fi

  # Keep a small audit record so you can diagnose boot/OVF differences later.
  cp "$OVF" "$STAGE/original-template.ovf"
  cat > "$STAGE/IMPORT-INFO.txt" <<EOF_IMPORT
Imported by ForgeMill ESXi Main Template Importer v2.0
Template: $VMNAME
OVA source: $BASE_URL/$FILE
OVA SHA256: $OVA_SHA256
Firmware: $FW
Disk controller: $DISK_CTRL ${DISK_SUB:-}
CHR keyboard workaround: $IS_CHR (keyboard.allowBothIRQs = FALSE when 1)
ESXi datastore: $DS
Network port group: $PORTGROUP
ESXi build: $ESXI_VER
Imported on: $(date -u 2>/dev/null || printf 'not available')
Role: ForgeMill main-template source VM (not a native vCenter template).
Note: keep this VM powered off. Boot a clone and validate guest networking.
EOF_IMPORT

  # Remove copies only after complete image validation/conversion.
  if [ "$KEEP_SOURCE" != 1 ]; then
    rm -f "$OVA" "$STAGE/archive-files.txt" "$STAGE/ovf-hardware.txt"
    rm -rf "$SRC"
  fi

  # Publishing and registering is the only mutation of the ESXi inventory.
  # Keep the completed directory if registration fails, allowing manual repair.
  [ ! -e "$FINAL" ] || fail "Destination already exists: $FINAL"
  mv "$STAGE" "$FINAL" || fail "Cannot publish VM directory to $FINAL"
  ACTIVE_STAGE=''
  FINAL_VMX="$FINAL/$VMNAME.vmx"
  say 'Registering powered-off ForgeMill main-template source VM'
  VMID=$(vim-cmd solo/registervm "$FINAL_VMX") || fail "Registration failed; files retained at $FINAL"
  case "$VMID" in ''|*[!0-9]*) fail "Unexpected registration result '$VMID'; files retained at $FINAL" ;; esac
  vm_present=$(vim-cmd vmsvc/getallvms 2>&1 | awk -v n="$VMNAME" -v id="$VMID" '$1==id && $2==n {print "ok"; exit}')
  [ "$vm_present" = ok ] || fail "VMID $VMID registered but not valid in inventory; inspect $FINAL_VMX and /var/log/hostd.log"
  power_state=$(vim-cmd vmsvc/power.getstate "$VMID") || fail "Cannot query VM power state: $VMID"
  printf '%s\n' "$power_state"
  printf '%s\n' "$power_state" | grep -q 'Powered off' || fail 'Main-template source VM is unexpectedly powered on'
  info "SUCCESS: $VMNAME (VMID $VMID) at $FINAL"
  info 'Registered as a powered-off, annotated ForgeMill template source; native vCenter templates require vCenter.'
  if [ "$IS_CHR" = 1 ]; then
    warn 'CHR source uses BIOS+IDE+keyboard fix. IMPORTANT: unpatched ForgeMill ESXi fallback can change IDE to SCSI. Validate a deployed CHR VM with a fixed ForgeMill build.'
  fi
}

case "$MODE" in
  all)
    import_image ubuntu
    import_image rockyvmware
    import_image chr7237
    ;;
  ubuntu) import_image ubuntu ;;
  rocky|rockyvmware) import_image rockyvmware ;;
  mikrotik|chr|chr7237) import_image chr7237 ;;
esac

say 'Final ESXi virtual machine inventory'
vim-cmd vmsvc/getallvms
say 'Finished: import is complete; validate boot on clones before production'