# ForgeMill ESXi — Three Production Template Sources

**Installer:** `esxi-templates/import.sh` v2.0 for standalone VMware ESXi 7.x and 8.x using a BusyBox-compatible shell. No Python, Docker or OVF Tool is installed on the ESXi host.

## The three source VMs

The default `all` action now creates **exactly three**, with the same names shown in ESXi and ForgeMill:

| VM name in ESXi and ForgeMill | Verified source OVA filename | Boot / hardware |
| --- | --- | --- |
| `Template-Ubuntu-24.04` | `ubuntu-24.04-server-cloudimg-amd64.ova` | Image-declared BIOS/SCSI, VMXNET3 |
| `Template-Rocky-9.8` | `rocky-9.8-forgemill-vmware.ova` | Legacy BIOS, PVSCSI, VMXNET3, VMware GuestInfo/cloud-init/open-vm-tools |
| `Template-MikroTik-CHR-7.23.7` | `chr-7.23.7-legacy-bios.ova` | Legacy BIOS, IDE 0:0, VMXNET3, `keyboard.allowBothIRQs = "FALSE"` |

The Rocky OVA was prepared with VMware Tools and cloud-init on a temporary Proxmox VM and the operator reported that a ForgeMill deployment works. Its known SHA-256 is **`2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33`**. The importer verifies this automatically. If the OVA is ever rebuilt, supply the independently measured new checksum in `ROCKY_VMWARE_SHA256`.

CHR 7.23.7 has been reported to boot with a fresh legacy-BIOS VMDK on ESXi-188. The keyboard/PS2 IRQ setting is based on the operator's reported recovery. The CHR and Ubuntu OVA files are **not included in GitHub**; they must be served from a trusted image server, and their whole-OVA checksums should be pinned using `CHR_7237_SHA256` and `UBUNTU_SHA256` when known. Without pins, the importer logs a warning and computes informational checksums but cannot authenticate a plain-HTTP image. Image compatibility and full first-boot behavior must be tested with a clone on each host.

## One-command fresh-host setup

Enable SSH in your new ESXi host's management UI, sign in as `root`, confirm the VM port group exists, and ensure it can reach your image server.

Default image URL is `http://172.31.31.183/iso`. By default the script automatically selects a mounted writable VMFS datastore with at least 12 GiB available and uses the standard port group **VM Network**.

```sh
wget --no-check-certificate -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh && sh -n /tmp/forgemill-esxi-import.sh && sh /tmp/forgemill-esxi-import.sh check && sh /tmp/forgemill-esxi-import.sh all && sh /tmp/forgemill-esxi-import.sh status
```

The `--no-check-certificate` workaround is only for ESXi builds that cannot validate the raw.githubusercontent.com certificate. **For a high-trust environment, download and verify the script from a pinned audited Git commit rather than running moving `main` with TLS checks disabled.** The command executes downloaded code as ESXi root and should only be used after review.

Specify another datastore or network before the `sh ... all` command:

```sh
DATASTORE='DISK1-raid1' PORTGROUP='VM Network' BASE_URL='http://172.31.31.183/iso' sh /tmp/forgemill-esxi-import.sh all
```

In a fresh deployment with independently trusted OVA checksums:

```sh
UBUNTU_SHA256='64-char-actual-hash' CHR_7237_SHA256='64-char-actual-hash' \
  sh /tmp/forgemill-esxi-import.sh all
```

**Use actual 64-character SHA-256 values**; the placeholders above are not valid. For independently measured hashes on the image server:

```sh
cd /var/lib/vz/template/iso
sha256sum ubuntu-24.04-server-cloudimg-amd64.ova chr-7.23.7-legacy-bios.ova rocky-9.8-forgemill-vmware.ova
```

## Individual operations

```sh
sh /tmp/forgemill-esxi-import.sh check
sh /tmp/forgemill-esxi-import.sh ubuntu
sh /tmp/forgemill-esxi-import.sh rocky
sh /tmp/forgemill-esxi-import.sh mikrotik
sh /tmp/forgemill-esxi-import.sh status
```

Backwards-compatible aliases: `rockyvmware` = `rocky`; `chr` / `chr7237` = `mikrotik`. The older Rocky OVA and CHR 7.19.6 are no longer part of `all`.

Other optional variables: `BASE_URL`, `DATASTORE`, `PORTGROUP`, `MIN_FREE_GB`, `KEEP_SOURCE=1`, `KEEP_FAILED=1`, `WGET_NO_CHECK_CERT=1`. The latter bypasses validation for HTTPS OVA downloads and is not recommended. Imported VMs are powered **off** and are never automatically booted by the importer.

## Security and idempotency

The installer rejects an unrecognized ESXi version, missing VMware command-line tools, missing VM network, unwritable/insufficient VMFS, bad OVA manifest/whole-file checksum, unsupported firmware/controller, unsafe archive names, or conflicting existing legacy template registrations/directories. It converts one boot VMDK with `vmkfstools` and verifies its disk chain before publishing. It does not delete old VMs, alter ESXi networking/firewall or overwrite VM disks. Re-running after success skips already registered templates without updating their configuration; **a skip is not a replacement or deep VMX validation**.

Old source names that can block duplicate installation on the same host include `ubuntu-24.04-golden`, `ubuntu-24.04-main-template`, `rocky-9.8-golden`, `rocky-9.8-forgemill-main-template`, and `mikrotik-chr-7.23.7-main-template`. This is deliberate: do not create duplicates while deployments still reference the older source VM.

## IMPORTANT: ForgeMill application cloning is a separate prerequisite

Standalone ESXi does not provide vCenter's native template objects; ForgeMill enumerates powered-off VMs as source templates. **Importing all three does not guarantee that the ForgeMill control panel can deploy all three.**

The unpatched upstream `blink-zero/forgemill` standalone-ESXi fallback constructs a SCSI controller even when the source disk is IDE. This can break MikroTik CHR boot, and it does not explicitly preserve the source's `keyboard.allowBothIRQs` VMX extraConfig. An ESXi shell importer cannot fix a deployment VM constructed by the ForgeMill application. Use a ForgeMill application build with the appropriate IDE/controller/keyboard preservation fix, and **boot-test a CHR clone** before considering it production-ready.

Rocky's working `forgemill` password/DHCP/VMware Tools result was reported on ESXi-188. Ubuntu's cloud-init credentials/DHCP have **not been freshly revalidated** in this installation turn. On each new host, deploy one test clone of every image and validate login, network/console, VMware Tools when available, and guest reboot/persistence. CHR normally does not run the VMware Tools guest reboot integration.

If ForgeMill's template sync fails with SQLite `FOREIGN KEY constraint failed (787)`, follow the separate, backup-first recovery steps in the [main project README](../README.md). Do not remove deployment references or disable foreign keys to force a sync.

## After installation

Open ForgeMill, connect to standalone ESXi on TCP 443 with an authorized account and suitable TLS validation settings, and sync templates. The source VMs must remain powered **off**. Confirm the three display names above and validate deploy/boot **on clones only**.

The independent ESXi importer does not install the ForgeMill Ubuntu control-plane itself. That is the separate [installer](../install-forgemill.bash).
