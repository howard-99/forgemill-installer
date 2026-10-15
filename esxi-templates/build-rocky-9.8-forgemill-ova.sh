#!/usr/bin/env bash
# Build ESXi-ready Rocky 9.8 OVA from official GenericCloud QCOW2.
# Run in a separate Ubuntu/Debian build VM, NOT directly on Proxmox or ESXi.
# Copy the output OVA back to the Proxmox image server after building.
set -Eeuo pipefail
umask 077
ISO_DIR=${ISO_DIR:-/srv/forgemill-images}
SOURCE=${SOURCE:-$ISO_DIR/Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2}
WORK=${WORK:-$ISO_DIR/forgemill-rocky-9.8-build}
NAME=rocky-9.8-forgemill-vmware
QCOW2=$WORK/$NAME.qcow2
VMDK=$WORK/$NAME-disk1.vmdk
OVF=$WORK/$NAME.ovf
MF=$WORK/$NAME.mf
OUTPUT=$ISO_DIR/$NAME.ova

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
[[ $EUID -eq 0 ]] || die 'Run as root in an isolated Linux build VM'
if command -v pveversion >/dev/null 2>&1; then
  die 'Refusing to run directly on a Proxmox VE host; use a temporary Ubuntu build VM'
fi
[[ -f "$SOURCE" ]] || die "Missing source QCOW2: $SOURCE"
[[ ! -e "$OUTPUT" && ! -e "$WORK" ]] || die 'Output or build directory exists; no overwrite'
for exe in qemu-img virt-customize virt-inspector python3 sha256sum cp; do
  command -v "$exe" >/dev/null || die "Missing $exe; apt install qemu-utils libguestfs-tools python3"
done

info 'Validating source QCOW2'
qemu-img info -f qcow2 "$SOURCE"
qemu-img check -f qcow2 "$SOURCE"
export LIBGUESTFS_BACKEND=direct
virt-inspector -a "$SOURCE" >/dev/null || die 'Guest inspection failed'
mkdir -m 0700 "$WORK"
cp --reflink=auto --sparse=always "$SOURCE" "$QCOW2"

cat > "$WORK/91-forgemill-vmware.cfg" <<'EOF_CLOUD'
# Standalone ESXi GuestInfo metadata + user-data
datasource_list: [ VMware, None ]
EOF_CLOUD
cat > "$WORK/90-forgemill-fallback.nmconnection" <<'EOF_NM'
[connection]
id=forgemill-fallback-dhcp
type=ethernet
autoconnect=true
autoconnect-priority=-50

[ipv4]
method=auto

[ipv6]
method=auto
EOF_NM
cat > "$WORK/60-forgemill-ssh.conf" <<'EOF_SSH'
PasswordAuthentication yes
PermitRootLogin no
EOF_SSH

# libguestfs runs DNF inside its own QEMU appliance, not the builder's
# network namespace. The cloud image can have a missing/stub resolv.conf,
# so temporarily supply reachable resolvers only while DNF runs.
# Restore the original resolv.conf before preparing the template.
cat > "$WORK/install-packages.sh" <<'EOF_PACKAGES'
#!/bin/sh
set -eu
backed_up=0
if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
  mv /etc/resolv.conf /etc/resolv.conf.forgemill-build-backup
  backed_up=1
fi
restore_resolver() {
  rm -f /etc/resolv.conf
  if [ "$backed_up" -eq 1 ]; then
    mv /etc/resolv.conf.forgemill-build-backup /etc/resolv.conf
  fi
}
trap restore_resolver EXIT
printf '%s\\n' 'nameserver 1.1.1.1' 'nameserver 8.8.8.8' > /etc/resolv.conf
echo '[rocky-build] Checking DNS inside the libguestfs guest environment'
getent ahostsv4 mirrors.rockylinux.org >/dev/null || {
  echo '[rocky-build] Guest DNS failed even with explicit resolvers; check libguestfs QEMU user networking/firewall' >&2
  exit 1
}
echo '[rocky-build] Guest DNS OK; installing VMware dependencies'
dnf -y install cloud-init open-vm-tools NetworkManager openssh-server sudo
EOF_PACKAGES
chmod 700 "$WORK/install-packages.sh"
info 'Installing VMware tools, cloud-init and DHCP/SSH integration'
virt-customize --network -a "$QCOW2" \
 --run "$WORK/install-packages.sh" \
 --mkdir /etc/ssh/sshd_config.d \
 --copy-in "$WORK/91-forgemill-vmware.cfg:/etc/cloud/cloud.cfg.d" \
 --copy-in "$WORK/90-forgemill-fallback.nmconnection:/etc/NetworkManager/system-connections" \
 --copy-in "$WORK/60-forgemill-ssh.conf:/etc/ssh/sshd_config.d" \
 --run-command 'groupadd -f sudo' \
 --run-command 'chmod 600 /etc/NetworkManager/system-connections/90-forgemill-fallback.nmconnection' \
 --run-command 'python3 -c "import cloudinit.sources.DataSourceVMware"' \
 --run-command 'systemctl enable NetworkManager sshd vmtoolsd cloud-init-local cloud-init cloud-config cloud-final' \
 --run-command 'cloud-init clean --logs --machine-id' \
 --run-command 'rm -f /etc/ssh/ssh_host_*'

# Optional break-glass SSH-key-only account; never bake shared passwords.
if [[ -n "${RECOVERY_PUBKEY_FILE:-}" ]]; then
 [[ -s "$RECOVERY_PUBKEY_FILE" ]] || die "Missing key: $RECOVERY_PUBKEY_FILE"
 virt-customize -a "$QCOW2" \
  --run-command 'id fmrecovery >/dev/null 2>&1 || useradd -m -s /bin/bash -G wheel fmrecovery' \
  --run-command 'passwd -l fmrecovery || true' \
  --run-command 'install -d -m 0700 -o fmrecovery -g fmrecovery /home/fmrecovery/.ssh' \
  --upload "$RECOVERY_PUBKEY_FILE:/home/fmrecovery/.ssh/authorized_keys" \
  --run-command 'chmod 600 /home/fmrecovery/.ssh/authorized_keys; chown fmrecovery:fmrecovery /home/fmrecovery/.ssh/authorized_keys' \
  --run-command "printf '%s\n' 'fmrecovery ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/99-forgemill-recovery; chmod 440 /etc/sudoers.d/99-forgemill-recovery"
fi

virt-inspector -a "$QCOW2" >/dev/null
qemu-img check -f qcow2 "$QCOW2"
info 'Converting prepared disk to streamOptimized VMDK'
qemu-img convert -p -f qcow2 -O vmdk -o subformat=streamOptimized,compat6 "$QCOW2" "$VMDK"
qemu-img info -f vmdk "$VMDK"

info 'Creating OVF, manifest and OVA archive'
python3 - "$QCOW2" "$VMDK" "$OVF" "$MF" "$OUTPUT" <<'PY'
import hashlib,json,pathlib,subprocess,sys,tarfile,xml.etree.ElementTree as ET
qcow,vmdk,ovf,mf,out = map(pathlib.Path,sys.argv[1:])
details=json.loads(subprocess.check_output(['qemu-img','info','-f','qcow2','--output=json',str(qcow)],text=True))
cap=int(details['virtual-size'])
name='rocky-9.8-forgemill-vmware'
xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">
<References><File ovf:id="file1" ovf:href="{vmdk.name}" ovf:size="{vmdk.stat().st_size}" /></References>
<DiskSection><Info>Disk</Info><Disk ovf:diskId="disk1" ovf:fileRef="file1" ovf:capacity="{cap}" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized" /></DiskSection>
<NetworkSection><Info>Network</Info><Network ovf:name="VM Network"><Description>Installer selects port group</Description></Network></NetworkSection>
<VirtualSystem ovf:id="{name}"><Info>Rocky 9.8 VMware</Info><Name>{name}</Name>
<OperatingSystemSection ovf:id="107"><Info>Linux</Info><Description>Rocky Linux 9 64 bit</Description></OperatingSystemSection>
<VirtualHardwareSection><Info>Devices</Info>
<System><vssd:ElementName>Virtual machine</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>{name}</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-17</vssd:VirtualSystemType></System>
<Item>
<rasd:InstanceID>1</rasd:InstanceID>
<rasd:ResourceType>3</rasd:ResourceType>
<rasd:VirtualQuantity>2</rasd:VirtualQuantity>
</Item>
<Item>
<rasd:InstanceID>2</rasd:InstanceID>
<rasd:ResourceType>4</rasd:ResourceType>
<rasd:VirtualQuantity>2048</rasd:VirtualQuantity>
<rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
</Item>
<Item>
<rasd:InstanceID>3</rasd:InstanceID>
<rasd:ResourceType>6</rasd:ResourceType>
<rasd:ResourceSubType>lsilogicsas</rasd:ResourceSubType>
</Item>
<Item>
<rasd:InstanceID>4</rasd:InstanceID>
<rasd:ResourceType>17</rasd:ResourceType>
<rasd:Parent>3</rasd:Parent>
<rasd:AddressOnParent>0</rasd:AddressOnParent>
<rasd:HostResource>ovf:/disk/disk1</rasd:HostResource>
</Item>
<Item>
<rasd:InstanceID>5</rasd:InstanceID>
<rasd:ResourceType>10</rasd:ResourceType>
<rasd:ResourceSubType>VmxNet3</rasd:ResourceSubType>
<rasd:Connection>VM Network</rasd:Connection>
</Item>
<vmw:Config vmw:key="firmware" vmw:value="bios"/>
</VirtualHardwareSection></VirtualSystem></Envelope>
'''
ET.fromstring(xml)
ovf.write_text(xml,encoding='utf-8')
def sha(file):
 h=hashlib.sha256()
 with file.open('rb') as f:
  for block in iter(lambda:f.read(4*1024*1024),b''): h.update(block)
 return h.hexdigest()
mf.write_text(f'SHA256({ovf.name})= {sha(ovf)}\nSHA256({vmdk.name})= {sha(vmdk)}\n',encoding='ascii')
with tarfile.open(out,'w',format=tarfile.USTAR_FORMAT) as archive:
 for f in [ovf,mf,vmdk]: archive.add(f,arcname=f.name,recursive=False)
with tarfile.open(out,'r') as archive:
 assert archive.getnames()==[ovf.name,mf.name,vmdk.name]
print('OVA:',out)
print('OVA SHA256:',sha(out))
print('Virtual disk size:',cap)
PY
info "Ready for ESXi import candidate testing: $OUTPUT"
info 'Original image intact; test ESXi boot, DHCP, credentials, tools before promoting to production.'
