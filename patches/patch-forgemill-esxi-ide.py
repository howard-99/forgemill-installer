#!/usr/bin/env python3
"""Apply fail-closed VMware standalone-ESXi IDE/keyboard fixes to upstream ForgeMill.

The upstream fallback's buildControllerFromTemplate defaults IDE to LSI Logic
SCSI. That makes a BIOS+IDE MikroTik image unbootable. CopyVirtualDisk also
hardcodes an LSI Logic adapter and the CreateVM config omits the VMX keyboard
IRQ setting proven useful on CHR 7.23.7.

This patch changes *only* standalone-ESXi fallback handling. A production
deployment/boot test on real ESXi is REQUIRED; compilation alone is not proof.
"""
from pathlib import Path
import argparse

def replace_once(source: str, old: str, new: str, label: str) -> str:
    count = source.count(old)
    if count != 1:
        raise ValueError(f"{label}: expected exact upstream block once; got {count}")
    return source.replace(old, new, 1)

def patch(source: str) -> str:
    if "FM-ESXI-IDE-FIX" in source:
        raise ValueError("IDE fix already applied")
    source = replace_once(
        source,
        '''\t// Build a destSpec to control the disk format during copy.
\t// CopyVirtualDisk with nil spec inflates thin VMDKs to thick on ESXi.
\t// VirtualDiskSpec.AdapterType is required by ESXi (empty string causes task failure).
\t// lsiLogic is the correct value for both lsiLogic and pvscsi SCSI controllers.
\tdiskType := types.VirtualDiskTypeThin''',
        '''\t// FM-ESXI-IDE-FIX: use an IDE VMDK adapter when cloning an IDE source.
\t// CopyVirtualDisk with nil spec may inflate thin disks on ESXi; keep the
\t// requested provisioning whenever the VirtualDiskManager accepts it.
\tcopyAdapterType := string(types.VirtualDiskAdapterTypeLsiLogic)
\tfor _, dev := range vmProps.Config.Hardware.Device {
\t\tif dev.GetVirtualDevice().Key == controllerKey {
\t\t\tif _, ok := dev.(*types.VirtualIDEController); ok {
\t\t\t\tcopyAdapterType = "ide"
\t\t\t}
\t\t\tbreak
\t\t}
\t}
\tdiskType := types.VirtualDiskTypeThin''',
        "select VMDK adapter",
    )
    source = replace_once(
        source,
        '''\t\tAdapterType: string(types.VirtualDiskAdapterTypeLsiLogic),''',
        '''\t\tAdapterType: copyAdapterType,''',
        "copy VMDK adapter",
    )
    source = replace_once(
        source,
        '''\t// Add a SCSI controller matching the template.
\tctrlSpec := buildControllerFromTemplate''',
        '''\t// Add a controller matching the template (IDE or SCSI).
\tctrlSpec := buildControllerFromTemplate''',
        "controller comment",
    )
    source = replace_once(
        source,
        '''\t// Inject cloud-init credentials and network config via guestinfo — the
\t// same properties the clone path sets (see cloudInitExtraConfig).
\tconfigSpec.ExtraConfig = append(configSpec.ExtraConfig, cloudInitExtraConfig(spec)...)

\t// Create the VM.''',
        '''\t// FM-ESXI-IDE-FIX: explicitly retain the template console keyboard IRQ
\t// workaround when the standalone-ESXi fallback builds a new VM.
\tfor _, entry := range vmProps.Config.ExtraConfig {
\t\tif opt, ok := entry.(*types.OptionValue); ok && opt.Key == "keyboard.allowBothIRQs" {
\t\t\tconfigSpec.ExtraConfig = append(configSpec.ExtraConfig, &types.OptionValue{
\t\t\t\tKey: "keyboard.allowBothIRQs", Value: opt.Value,
\t\t\t})
\t\t}
\t}
\t// Inject cloud-init credentials and network config via guestinfo — the
\t// same properties the clone path sets (see cloudInitExtraConfig).
\tconfigSpec.ExtraConfig = append(configSpec.ExtraConfig, cloudInitExtraConfig(spec)...)

\t// Create the VM.''',
        "keyboard extraConfig",
    )
    source = replace_once(
        source,
        '''// buildControllerFromTemplate creates a SCSI controller device spec matching
// the controller used by the template's primary disk.''',
        '''// buildControllerFromTemplate creates the IDE or SCSI controller used by
// the template's primary disk (including legacy-BIOS MikroTik CHR).''',
        "build controller comment",
    )
    source = replace_once(
        source,
        '''\t\tswitch dev.(type) {
\t\tcase *types.ParaVirtualSCSIController:''',
        '''\t\tswitch dev.(type) {
\t\tcase *types.VirtualIDEController:
\t\t\tspec.Device = &types.VirtualIDEController{
\t\t\t\tVirtualController: types.VirtualController{
\t\t\t\t\tVirtualDevice: types.VirtualDevice{Key: -1},
\t\t\t\t\tBusNumber:     0,
\t\t\t\t},
\t\t\t}
\t\t\treturn spec
\t\tcase *types.ParaVirtualSCSIController:''',
        "IDE controller",
    )
    for marker in ('copyAdapterType = "ide"', 'case *types.VirtualIDEController:', 'opt.Key == "keyboard.allowBothIRQs"'):
        if marker not in source:
            raise ValueError("missing expected patched marker " + marker)
    return source

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", type=Path)
    args = ap.parse_args()
    src = args.file.read_text(encoding="utf-8")
    args.file.write_text(patch(src), encoding="utf-8")
    print("Patched standalone-ESXi fallback: VMDK adapter + IDE controller + keyboard IRQ.")
    print("Still required: CI compile and successful deployment boot on real ESXi.")

if __name__ == "__main__":
    main()
