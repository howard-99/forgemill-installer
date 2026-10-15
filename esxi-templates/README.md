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

## Fresh ESXi bootstrap — use the local image server, not GitHub HTTPS

**Problem observed on newly installed ESXi:** the ESXi BusyBox `wget`
hangs at `Connecting to raw.githubusercontent.com (...:443)`, even though
`ping raw.githubusercontent.com` works. DNS/ICMP reachability does not
establish HTTPS/TLS connectivity. The importer never starts in that case.

**Preferred reliable deployment path:** publish the installer **once** on
the Linux/Proxmox image server (`172.31.31.183`), then install from the
same local HTTP endpoint that is already serving the three OVAs. This
avoids GitHub HTTPS from every ESXi host.

### A. On the Linux image server (Proxmox 183), prepare the installer

```bash
curl -fL https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/publish-to-image-server.sh -o /root/publish-forgemill-esxi.sh
bash -n /root/publish-forgemill-esxi.sh
bash /root/publish-forgemill-esxi.sh
curl -I http://172.31.31.183/iso/forgemill-esxi-import.sh
```

The publisher downloads `import.sh` with certificate validation **on
Linux**, validates POSIX syntax, computes its SHA-256, sets read permission
for the web server, and atomically publishes to
`/var/lib/vz/template/iso/forgemill-esxi-import.sh`. It never modifies
VMs, the Proxmox package set or the OVA files. **Record its SHA-256 hash
from the output and verify the same value on ESXi.** When you update
GitHub, rerun the publisher to refresh the local script.

For reproducible installations, pin a trusted *full* Git commit SHA
instead of using moving `main`: set `FORGEMILL_IMPORT_REF=...` when
running the publisher. Optional `EXPECTED_SCRIPT_SHA256=...` verifies
the fetched installer against an independently obtained hash.

If the Linux image server also cannot reach GitHub, obtain the installer
over a working authenticated channel on another workstation and
securely copy it into the image server's `/var/lib/vz/template/iso/`
directory, then verify its checksum and readability before publishing.

### B. One command on EACH newly installed ESXi host

Enable SSH, log in as root and run:

```sh
wget -O /tmp/forgemill-esxi-import.sh http://172.31.31.183/iso/forgemill-esxi-import.sh && sh -n /tmp/forgemill-esxi-import.sh && sh /tmp/forgemill-esxi-import.sh check && sh /tmp/forgemill-esxi-import.sh all && sh /tmp/forgemill-esxi-import.sh status
```

**Before running on a production host, compare**
`sha256sum /tmp/forgemill-esxi-import.sh` to the SHA-256 printed by
the trusted publisher in step A; the single command is a convenience,
not a replacement for integrity verification.

This command defaults to `http://172.31.31.183/iso` for the OVAs,
chooses a writable VMFS datastore with at least 12 GiB available,
and uses the port group **VM Network**. All imported source VMs remain
powered **off**.

To customize the datastore, port group and image-server URL after
downloading:

```sh
DATASTORE='DISK1-raid1' PORTGROUP='VM Network' BASE_URL='http://172.31.31.183/iso' sh /tmp/forgemill-esxi-import.sh all
```

For stronger image-integrity protection, use independently verified hashes:

```sh
UBUNTU_SHA256='ACTUAL_64_HEX_DIGEST' CHR_7237_SHA256='ACTUAL_64_HEX_DIGEST' sh /tmp/forgemill-esxi-import.sh all
```

Replace both placeholders with the actual hashes; otherwise omit those
variables (the script warns for unsigned/unpinned HTTP sources). The
Rocky OVA is pinned by default.

On the image server, obtain hashes with:

```bash
cd /var/lib/vz/template/iso
sha256sum ubuntu-24.04-server-cloudimg-amd64.ova chr-7.23.7-legacy-bios.ova rocky-9.8-forgemill-vmware.ova
```

### C. If the local HTTP download also fails

On the ESXi host, test directly:

```sh
ping -c 2 172.31.31.183
wget -O /tmp/forgemill-esxi-import.sh http://172.31.31.183/iso/forgemill-esxi-import.sh
ls -lh /tmp/forgemill-esxi-import.sh
```

If the HTTP request times out, verify the image server is listening
on TCP 80 and that the ESXi management network can route to it.
A successful ping to GitHub says nothing about the TCP connection
to GitHub's port 443. Do not disable ESXi's firewall globally,
change DNS at random, or use an unauthenticated third-party script mirror.

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
