# ForgeMill standalone ESXi — fresh host templates (v2.3)

This importer prepares **three powered-off source VMs** for discovery by ForgeMill
on standalone ESXi 7.x/8.x. It runs in the ESXi BusyBox shell and does not
require Python, Docker, vCenter or ovftool on ESXi.

**Important: Ubuntu and Rocky use OVA. MikroTik 7.21rc6 uses the direct VMDK
that successfully booted with working console keyboard in an isolated
test VM on ESXi `172.31.31.192`. It is NOT an OVA.**

## Recommended: tested direct-GitHub install on fresh ESXi

Enable ESXi SSH, log in as root and run the following commands. They
worked on a freshly installed ESXi host in the operator's environment:

```sh
esxcli network firewall ruleset set -e true -r httpClient

wget --no-check-certificate -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh

sh /tmp/forgemill-esxi-import.sh all
```

`--no-check-certificate` disables TLS verification of the downloaded
script; to reduce supply-chain risk, verify the script checksum against
an independently trusted GitHub checkout before executing it.

**This downloads the importer directly from GitHub, not the three VM
images.** By default the importer still pulls its two OVAs and CHR VMDK
from `http://172.31.31.183/iso`. Those images must be reachable from
each new ESXi host or mirrored to another server using `BASE_URL`.
This does not eliminate the default image-host dependency.

## Default three sources

| ESXi/ForgeMill VM name | Local HTTP source under `/iso/` | Hardware |
| --- | --- | --- |
| `Template-Ubuntu-24.04` | `ubuntu-24.04-server-cloudimg-amd64.ova` | Firmware/controller declared by the OVA, VMXNET3 |
| `Template-Rocky-9.8` | `rocky-9.8-forgemill-vmware.ova` | BIOS, PVSCSI, VMXNET3 |
| `Template-MikroTik-CHR-7.21rc6` | `chr-7.21rc6-legacy-bios.vmdk` | BIOS, IDE 0:0, VM hardware 17, 1 CPU, 1 GiB RAM, VMXNET3, default keyboard |

**No CHR PS/2 or USB keyboard workarounds are added to the 7.21rc6 VMX.**
The successful direct 7.21rc6 test used BIOS, IDE, VMX-17 and no keyboard
overrides. Our ForgeMill source additionally includes a VMXNET3 NIC so it
can be selected for networked deployments. That NIC configuration and
**ForgeMill's ability to clone it with a working keyboard are not yet
validated** by the direct-console test.

The default `all` no longer imports `7.23.7`. The separate `chr7196`
mode remains available *only* for historical diagnostics; it is not part
of `all`. Existing 7.23.7 templates and previous deployments are never
deleted, changed, renamed or powered on by this installer.

## Optional fallback: publish the script on the Proxmox HTTP image server

Use this alternate path only if the direct-GitHub installer-script download
does not work on a particular ESXi host. This step is **not needed**
when the recommended commands above work. Download from GitHub on
**the Linux image server**, then allow ESXi to fetch the same installer
over LAN HTTP from the host serving the VM images.

Run on Proxmox `172.31.31.183`:

```bash
cd /var/lib/vz/template/iso

# Ensure all three images are accessible to the image web server.
ls -lh ubuntu-24.04-server-cloudimg-amd64.ova \
       rocky-9.8-forgemill-vmware.ova \
       chr-7.21rc6-legacy-bios.vmdk

# Show independently trusted checksums, particularly the CHR VMDK.
sha256sum chr-7.21rc6-legacy-bios.vmdk

# Download or refresh the image-server publisher:
curl -fsSL https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/publish-to-image-server.sh \
  -o /root/publish-forgemill-esxi.sh
bash -n /root/publish-forgemill-esxi.sh
bash /root/publish-forgemill-esxi.sh

# Verify HTTP publication and note the script checksum from publisher output.
curl -fI http://172.31.31.183/iso/forgemill-esxi-import.sh
sha256sum /var/lib/vz/template/iso/forgemill-esxi-import.sh
```

The publisher uses verified HTTPS on Linux, validates shell syntax and
atomically publishes `forgemill-esxi-import.sh`. It does **not** change
any VM or OVA. It refreshes the server's copy **only when you run it**;
changing GitHub alone does not refresh a previously published script.

For reproducibility, set `FORGEMILL_IMPORT_REF` to a reviewed full
40-character Git commit SHA rather than relying on the moving `main`
branch. Use `EXPECTED_SCRIPT_SHA256` to validate independently obtained
script digests.

## Alternative: install using the LAN-published script

Enable SSH on ESXi and log in as `root`. By default, the installer selects
a writable VMFS datastore with at least **12 GiB free**, uses standard
port group `VM Network`, and downloads all three image files from
`http://172.31.31.183/iso`.

```sh
wget -O /tmp/forgemill-esxi-import.sh http://172.31.31.183/iso/forgemill-esxi-import.sh && sh -n /tmp/forgemill-esxi-import.sh && sh /tmp/forgemill-esxi-import.sh check && sh /tmp/forgemill-esxi-import.sh all && sh /tmp/forgemill-esxi-import.sh status
```

**Security:** HTTP does not authenticate scripts or VM images. For
production, split the command after download and verify:

```sh
sha256sum /tmp/forgemill-esxi-import.sh
```

Compare against the checksum printed on Proxmox, before executing the
script. If the checksums do not match, stop. Pin the CHR checksum too:

```sh
CHR_721RC6_SHA256='YOUR_ACTUAL_64_HEX_SHA256' \
DATASTORE='DISK1-raid1' PORTGROUP='VM Network' \
BASE_URL='http://172.31.31.183/iso' \
sh /tmp/forgemill-esxi-import.sh all
```

Replace the placeholder with the VMDK's *actual* hash from Proxmox.
If you omit it, the installer warns that the HTTP source is unauthenticated;
it still computes a checksum and checks the converted VMDK chain. The
Rocky VMware OVA is pinned automatically to its verified digest
`2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33`.

### Individual actions

```sh
sh /tmp/forgemill-esxi-import.sh check
sh /tmp/forgemill-esxi-import.sh ubuntu
sh /tmp/forgemill-esxi-import.sh rocky
sh /tmp/forgemill-esxi-import.sh mikrotik    # CHR 7.21rc6 ONLY
sh /tmp/forgemill-esxi-import.sh chr721rc6  # same as mikrotik
sh /tmp/forgemill-esxi-import.sh status
```

The optional legacy `chr7196` mode is available for diagnostics.
There is intentionally **no new 7.23.7 import mode**.

## Safety and VM behavior

The importer:

- Checks ESXi version, datastore, networking and available utilities.
- Refuses registered source names and conflicting source directories.
- Downloads OVA sources into staging, validates manifest hashes, checks
  controller/firmware, then clones their VMDKs.
- Downloads the 7.21rc6 **VMDK directly**, checks optional SHA-256, converts
  it to native thin VMFS with `vmkfstools -i`, then runs `vmkfstools -e`.
- Registers powered-off source VMs; does not power on, shut down, overwrite,
  unregister or delete existing VMs.
- Does not install or alter ESXi firewall, management NIC or DNS settings.

A rerun skips existing templates rather than updating their VMX.
The imported images are powered-off **VM sources**, not native vCenter
template objects.

**Caution about ForgeMill deployment:** The original upstream standalone
ESXi fallback rebuilt MikroTik's IDE disks as SCSI and didn't preserve
all template VMX settings. The working keyboard result was for a
**directly created** 7.21rc6 VM, not a VM cloned by ForgeMill. A source
import alone does not fix that application-side cloning problem.
This repository has an opt-in
[application patch](../patches/patch-forgemill-esxi-ide.py) and
[build workflow](../.github/workflows/build-fork-syncfix.yml), but
you must build, install and test the patched ForgeMill image separately.
After syncing the ESXi target, test deploying a *new* disposable 7.21rc6
VM and verify its console, firmware, disk controller, network and power.

CHR 7.21rc6 is a prerelease third-party image; evaluate provenance,
security, licensing and RouterOS stability before production use.

See the main [repository README](../README.md) for first-priority fresh
**Ubuntu ForgeMill installation** and recovery from ForgeMill template
sync's SQLite FK-787 bug.
