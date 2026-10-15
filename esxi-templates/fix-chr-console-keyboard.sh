#!/bin/sh
# ESXi 7/8: inspect or safely repair the missing MikroTik PS/2 keyboard IRQ VMX option.
# Repair applies ONLY to an explicit, powered-off deployed VM, never a template.
# Usage: sh fix-chr-console-keyboard.sh inspect VMID
#        sh fix-chr-console-keyboard.sh apply VMID
set -eu

PATH="/bin:/sbin:/usr/bin:/usr/sbin:${PATH:-}"
export PATH

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

[ "$#" -eq 2 ] || fail 'Usage: sh fix-chr-console-keyboard.sh inspect|apply VMID'
MODE=$1
VMID=$2
case "$MODE" in inspect|apply) ;; *) fail 'Mode must be inspect or apply' ;; esac
case "$VMID" in ''|*[!0-9]*) fail 'VMID must be a decimal ESXi VM identifier';; esac
command -v vim-cmd >/dev/null 2>&1 || fail 'This script must run in ESXi shell (vim-cmd missing)'

VMROW=$(vim-cmd vmsvc/getallvms | awk -v n="$VMID" '$1 == n {print; exit}') ||
  fail 'Unable to query ESXi inventory'
[ -n "$VMROW" ] || fail "VMID $VMID is not registered on this host"
VMNAME=$(printf '%s\n' "$VMROW" | awk '{print $2}')
case "$(printf '%s\n' "$VMNAME" | tr '[:upper:]' '[:lower:]')" in
  *template*|*golden*) fail "Refusing to change source VM named $VMNAME; select the DEPLOYED MikroTik clone" ;;
esac

CFG=$(vim-cmd vmsvc/get.config "$VMID") || fail "Cannot retrieve config for VMID $VMID"
VMX_REF=$(printf '%s\n' "$CFG" | sed -n 's/^[[:space:]]*vmPathName = "\([^"]*\.vmx\)".*/\1/p' | head -n 1)
case "$VMX_REF" in
  '['*'] '*'.vmx') ;;
  *) fail "Cannot safely parse VMX path: $VMX_REF" ;;
esac
DS=${VMX_REF#\[}
DS=${DS%%\]*}
REL=${VMX_REF#*\] }
case "$REL" in ''|/*|../*|*/../*|*/..|..|*'\\'*) fail "Unsafe VMX relative path: $REL" ;; esac
VMX="/vmfs/volumes/$DS/$REL"
[ -f "$VMX" ] || fail "VMX is missing: $VMX"

info "VM: $VMNAME (VMID $VMID)"
info "VMX: $VMX"
STATE=$(vim-cmd vmsvc/power.getstate "$VMID") || fail "Cannot query VM power state $VMID"
printf '%s\n' "$STATE"
grep -Ei '^[[:space:]]*(firmware|ide0:0.present|scsi0:0.present|keyboard\.allowBothIRQs)[[:space:]]*=' "$VMX" || true

if [ "$MODE" = inspect ]; then
  if ! grep -Eqi '^[[:space:]]*keyboard\.allowBothIRQs[[:space:]]*=' "$VMX"; then
    info 'Keyboard option MISSING on clone. Power off the test VM, then run apply.'
  fi
  exit 0
fi

case "$STATE" in *'Powered off'*) ;; *) fail 'Power off the DEPLOYED TEST VM in ESXi first; do not edit a running VMX' ;; esac
if grep -Eqi '^[[:space:]]*keyboard\.allowBothIRQs[[:space:]]*=' "$VMX"; then
  if grep -Eqi '^[[:space:]]*keyboard\.allowBothIRQs[[:space:]]*=[[:space:]]*"FALSE"[[:space:]]*$' "$VMX"; then
    info 'Keyboard option is already set to FALSE; nothing changed.'
    exit 0
  fi
  fail 'Keyboard option already exists but is not FALSE; inspect VMX manually before changing'
fi

BACKUP="$VMX.pre-chr-keyboard-$(date +%Y%m%d%H%M%S)"
[ ! -e "$BACKUP" ] || fail "Backup path already exists: $BACKUP"
cp "$VMX" "$BACKUP" || fail 'Failed to backup original VMX'
printf '\nkeyboard.allowBothIRQs = "FALSE"\n' >> "$VMX" ||
  fail "Unable to update VMX; backup retained at $BACKUP"
grep -Eq '^keyboard\.allowBothIRQs = "FALSE"$' "$VMX" ||
  fail 'Written VMX option failed verification'

vim-cmd vmsvc/reload "$VMID" || fail "VMX changed but reload failed; backup: $BACKUP"
info "Repair applied and VM configuration reloaded. Original VMX: $BACKUP"
info 'Now power on this TEST clone and check keyboard input at the RouterOS login prompt.'
info 'A new ForgeMill deployment needs the application-side keyboard extraConfig patch too.'
