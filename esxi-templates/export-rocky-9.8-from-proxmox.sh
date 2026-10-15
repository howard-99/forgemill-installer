#!/usr/bin/env bash
# Export PREPARED, powered-off Proxmox VM 100 (Rocky 9.8) as ESXi OVA.
# Read-only input (VM disk); does not install/remove packages or alter VM 100.
# Requires guest cleanup BEFORE shutdown (cloud-init, SSH keys, NoCloud profile).
set -Eeuo pipefail
umask 077
VMID=100
EXPECTED_VM_NAME='Rocky98-ForgeMill-Builder'
ISO_DIR=/var/lib/vz/template/iso
NAME=rocky-9.8-forgemill-vmware
OVA="$ISO_DIR/$NAME.ova"
[[ $EUID -eq 0 ]] || { echo 'Run as root on Proxmox VE' >&2; exit 1; }
for c in qm pvesm qemu-img python3 mktemp tar mv; do
  command -v "$c" >/dev/null || { echo "Missing $c" >&2; exit 1; }
done
command -v pveversion >/dev/null || { echo 'Not a Proxmox VE host' >&2; exit 1; }
[[ -d "$ISO_DIR" ]] || { echo "Missing $ISO_DIR" >&2; exit 1; }
[[ ! -e "$OVA" ]] || { echo "Refusing to overwrite existing $OVA" >&2; exit 1; }
CONF=$(qm config "$VMID")
printf '%s\n' "$CONF" | grep -qx "name: $EXPECTED_VM_NAME" || {
  echo "VM $VMID is not $EXPECTED_VM_NAME; refusing export" >&2; exit 1;
}
STATUS=$(qm status "$VMID")
[[ "$STATUS" == 'status: stopped' ]] || { echo "Power off VM $VMID cleanly first ($STATUS)" >&2; exit 1; }
VOLUME=$(printf '%s\n' "$CONF" | sed -n 's/^scsi0: \([^,]*\).*/\1/p')
[[ "$VOLUME" == 'local-lvm:vm-100-disk-0' ]] || {
  echo "Unexpected source volume '$VOLUME'; refusing to guess" >&2; exit 1;
}
DEVICE=$(pvesm path "$VOLUME")
[[ -b "$DEVICE" ]] || { echo "VM disk is not a block device: $DEVICE" >&2; exit 1; }
qemu-img info -f raw "$DEVICE"
STAGE=$(mktemp -d "$ISO_DIR/.rocky98-esxi-ova-XXXXXX")
cleanup() { rm -rf -- "$STAGE"; }
trap cleanup EXIT
VMDK="$STAGE/$NAME-disk1.vmdk"
OVF="$STAGE/$NAME.ovf"
MF="$STAGE/$NAME.mf"
echo "Converting stopped VM 100 disk ($DEVICE) to VMware streamOptimized VMDK"
qemu-img convert -p -f raw -O vmdk -o subformat=streamOptimized,compat6 "$DEVICE" "$VMDK"
qemu-img info -f vmdk "$VMDK"

python3 - "$DEVICE" "$VMDK" "$OVF" "$MF" "$STAGE/$NAME.ova" <<'PY'
import hashlib,json,pathlib,subprocess,sys,tarfile,xml.etree.ElementTree as ET
source,vmdk,ovf,mf,output=map(pathlib.Path,sys.argv[1:])
size=int(json.loads(subprocess.check_output(['qemu-img','info','-f','raw','--output=json',str(source)],text=True))['virtual-size'])
name='rocky-9.8-forgemill-vmware'
xml=f'''<?xml version="1.0" encoding="UTF-8"?>
<Envelope xmlns="http://schemas.dmtf.org/ovf/envelope/1" xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1" xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData" xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData" xmlns:vmw="http://www.vmware.com/schema/ovf">
<References><File ovf:id="file1" ovf:href="{vmdk.name}" ovf:size="{vmdk.stat().st_size}" /></References>
<DiskSection><Info>Disk information</Info><Disk ovf:diskId="disk1" ovf:fileRef="file1" ovf:capacity="{size}" ovf:capacityAllocationUnits="byte" ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized" /></DiskSection>
<NetworkSection><Info>Network</Info><Network ovf:name="VM Network"><Description>ESXi installer-configured portgroup</Description></Network></NetworkSection>
<VirtualSystem ovf:id="{name}"><Info>Rocky 9.8 VMware GuestInfo</Info><Name>{name}</Name>
<OperatingSystemSection ovf:id="107"><Info>Linux guest</Info><Description>Rocky Linux 9 (64-bit)</Description></OperatingSystemSection>
<VirtualHardwareSection><Info>VM hardware</Info>
<System><vssd:ElementName>VM hardware</vssd:ElementName><vssd:InstanceID>0</vssd:InstanceID><vssd:VirtualSystemIdentifier>{name}</vssd:VirtualSystemIdentifier><vssd:VirtualSystemType>vmx-17</vssd:VirtualSystemType></System>
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
<rasd:ResourceSubType>pvscsi</rasd:ResourceSubType>
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
</VirtualHardwareSection></VirtualSystem></Envelope>'''
ET.fromstring(xml)
ovf.write_text(xml,encoding='utf-8')
def sha(path):
 h=hashlib.sha256()
 with path.open('rb') as f:
  for chunk in iter(lambda:f.read(1024*1024),b''): h.update(chunk)
 return h.hexdigest()
mf.write_text(f'SHA256({ovf.name})= {sha(ovf)}\nSHA256({vmdk.name})= {sha(vmdk)}\n',encoding='ascii')
with tarfile.open(output,'w',format=tarfile.USTAR_FORMAT) as arc:
 for f in (ovf,mf,vmdk): arc.add(f,arcname=f.name,recursive=False)
with tarfile.open(output,'r') as arc:
 assert arc.getnames()==[ovf.name,mf.name,vmdk.name]
print('Prepared OVA SHA256:',sha(output))
print('Disk virtual size:',size)
PY

mv -- "$STAGE/$NAME.ova" "$OVA"
echo "SUCCESS: $OVA"
sha256sum "$OVA"
echo 'IMPORTANT: Boot and test on ESXi and through ForgeMill before using as default template.'
