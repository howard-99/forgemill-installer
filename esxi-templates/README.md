# ForgeMill ESXi Main Template Importer

A standalone BusyBox/POSIX-shell importer for **VMware ESXi 7.x/8.x**. It prepares powered-off main-template source VMs for discovery by [ForgeMill](https://github.com/blink-zero/forgemill), without installing Python, Docker, or OVF Tool on the ESXi host.

This is the **v1.7 importer (previous v1.4 tested on ESXi 7.0.3; new Rocky VMware candidate still requires ESXi validation)** by the project operator. Other hardware, OVA variants and ESXi releases should be tested before production use.

## Images

| Mode | Powered-off VM name | Expected image filename |
| --- | --- | --- |
| `ubuntu` | `ubuntu-24.04-main-template` | `ubuntu-24.04-server-cloudimg-amd64.ova` |
| `chr7196` | `mikrotik-chr-7.19.6-main-template` | `chr-7.19.6-legacy-bios.ova` |
| `chr7237` | `mikrotik-chr-7.23.7-main-template` | `chr-7.23.7-legacy-bios.ova` |
| `chr` / `mikrotik` | Both MikroTik legacy BIOS images | Both OVAs |
| `rocky` | `rocky-9.8-main-template` | `rocky-9.8.ova` |
| `rockyvmware` (opt-in) | `rocky-9.8-forgemill-main-template` | `rocky-9.8-forgemill-vmware.ova` |
| `all` | Ubuntu + Rocky + both CHR images | Four OVA files |

**OVAs are not included**. Host your own legal, trusted images on an HTTP(S) server accessible from each ESXi management network. The initial default is `http://172.31.31.183/iso` (a private LAN address from the original deployment); **override `BASE_URL` on other networks**.

## Run on ESXi SSH

SSH to your ESXi server as root (with console recovery access). First download the script, examine it, and perform the read-only preflight. The ESXi BusyBox TLS workaround below disables HTTPS certificate validation; **only use it if you have independently verified the script's integrity**, and prefer normal certificate validation where supported:

```sh
wget --no-check-certificate -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh
sh -n /tmp/forgemill-esxi-import.sh
sh /tmp/forgemill-esxi-import.sh check
```

Then import only the desired image(s):

```sh
sh /tmp/forgemill-esxi-import.sh all
# or:
sh /tmp/forgemill-esxi-import.sh rocky
sh /tmp/forgemill-esxi-import.sh rockyvmware  # candidate; separate from 'all'
sh /tmp/forgemill-esxi-import.sh chr
sh /tmp/forgemill-esxi-import.sh chr7196
sh /tmp/forgemill-esxi-import.sh chr7237
sh /tmp/forgemill-esxi-import.sh ubuntu
sh /tmp/forgemill-esxi-import.sh status
```

One-line **download + preflight only**:

```sh
wget -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh && sh /tmp/forgemill-esxi-import.sh check
```

One-line **download + import** (review code and preflight first; this writes new VM files to a datastore):

```sh
wget -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh && sh /tmp/forgemill-esxi-import.sh all
```

### Customize datastore, network and image URL

The installer selects a writable mounted VMFS datastore with the most available space and requires 12 GiB free by default. It will not use boot/system partitions and won't overwrite existing VM directories.

```sh
BASE_URL='http://YOUR-IMAGE-SERVER/iso' PORTGROUP='VM Network' DATASTORE='DISK1-raid1' sh /tmp/forgemill-esxi-import.sh all
```

Optional settings: `BASE_URL`, `PORTGROUP`, `DATASTORE`, `MIN_FREE_GB`, `KEEP_SOURCE=1`, `KEEP_FAILED=1`, `CHR_7196_SHA256`, `CHR_7237_SHA256`, `ROCKY_VMWARE_SHA256`, `WGET_NO_CHECK_CERT=1` (only for HTTPS OVA downloads; insecure). The initial GitHub script download requires its own `--no-check-certificate` flag on affected ESXi builds.

## Rocky 9.8 VMware test candidate (not enabled in `all`)

The separate `rockyvmware` mode imports an ESXi-ready OVA built on Proxmox from Rocky 9.8 GenericCloud and prepared for VMware GuestInfo-based cloud-init. Default OVA: `rocky-9.8-forgemill-vmware.ova`. The import source is `rocky-9.8-forgemill-main-template` and does NOT replace `rocky-9.8-main-template` or `rocky-9.8-golden`.

The known exported test file SHA-256 is `2a58c89a81b456e6c90cdae6d2d23152799cd137a42207d50b40d538b4274f33`; it is enforced by default in this mode. When you rebuild, supply the new verified value using `ROCKY_VMWARE_SHA256=...`.

Source prep and export builder scripts:
- [Build from GenericCloud on Ubuntu](build-rocky-9.8-forgemill-ova.sh) (legacy alternative, libguestfs may lack networking)
- [Export preconfigured, stopped Proxmox VM 100 to ESXi OVA](export-rocky-9.8-from-proxmox.sh) (current approach)

Never boot the registered source itself before cloning it: doing so may consume first-boot cloud-init state without deployment credentials. Boot a clone through ForgeMill; verify VMX firmware BIOS, PVSCSI boot, VMXNET3, VMware Tools IP reporting, DHCP address, and generated `forgemill` user login. The VMX is only a powered-off source; these outcomes are not proven yet. A pre-existing `rocky` local account may still exist on the prepared disk but no authorized key/password is intentionally provided to access it; audit the entire image before distributing to customers.

## MikroTik CHR compatibility and keyboard fix

The default importer now includes **two independently named Legacy BIOS CHR sources**, 7.19.6 and 7.23.7. Each is forced to **BIOS + IDE (0:0)** after inspecting the OVF. The VMX includes `keyboard.allowBothIRQs = "FALSE"`, the operator-reported keyboard workaround on ESXi-188. No USB virtual keyboard setting is required. This observation does not prove that the workaround is universal across all ESXi versions or hardware.

The installer defaults to `http://172.31.31.183/iso`, where both exact legacy BIOS OVA names must be available; it does not import the UEFI `chr-7.x.ova` images as CHR sources. Ensure files are trusted. Optional `CHR_7196_SHA256` and `CHR_7237_SHA256` values enforce expected digest matching; for example, obtain each trusted hash on the source machine before running the import. Existing templates are skipped without changing their VMX settings.

**Deployment limitation:** The upstream `blink-zero/forgemill` standalone-ESXi fallback currently does not preserve IDE boot controllers and can recreate disks as SCSI. A correctly imported and keyboard-configured source VM is **not enough** to guarantee ForgeMill-deployed CHR VMs boot or inherit the keyboard fix. The upstream clone fallback must preserve disk controller, source firmware, and keyboard-related extraConfig, then be regression-tested for both CHR versions. The installer in this repository cannot patch the running ForgeMill binary.

## Source VM vs native template

Standalone ESXi **cannot create native vCenter inventory templates**. Each import is a registered **powered-off VM** named `*-main-template`, with `annotation` and `guestinfo.forgemill.role = "main-template"` VMX metadata to document its purpose. These markers do not convert a VM to a native template. ForgeMill's standalone ESXi provider can use powered-off VMs as clone sources, subject to API/license compatibility. Actual native VMware template objects require vCenter.

The importer never automatically replaces or renames existing `*-golden` VMs. If a legacy VM/directory is present, a new import with the corresponding main-template name fails safely to prevent duplicate source images. Migrate existing names explicitly after backups and checking ForgeMill references.

## Behavior and safety

- Reads VMFS inventory and selects a writable datastore with sufficient free space.
- Validates the archive structure and supported OVF manifest checksums (if present).
- Detects the OVA firmware and boot-controller settings where supported; refuses unknown controller configurations.
- Converts a **single** VMDK to native thin VMFS format with `vmkfstools`.
- Writes a VMX, registers a powered-off VM and keeps an import audit file.
- Skips already registered main-template VMs; refuses to overwrite an existing main-template or legacy golden VM directory.
- Uses staging directories and cleans incomplete imports unless `KEEP_FAILED=1`.
- Does **not** reinstall ESXi, erase datastores, configure SSH firewall, power on VMs, or reset guests.

### Limits

- Requires an OVA with one OVF descriptor and one VMDK disk; multi-disk images are not supported.
- OVF hardware metadata is not fully reproduced; see the selected firmware/controller, and boot-test a clone.
- `check` probes datastore writability with a temporary empty directory (no VM modifications).
- A successful import is **not proof that the guest OS or cloud-init boots correctly**. Validate guest networking, VMware Tools, credentials and disk growth with a test clone.
- ForgeMill's standalone-ESXi provider considers powered-off VMs as template sources; they are not native vCenter templates. A matching annotation and VMX guestinfo marker make their intended role explicit.
- `mikrotik`/`chr` images require RouterOS-specific first-boot setup and licensing. Test console input via ESXi web console and VMRC after cloning; guest reboot requires VMware Tools support and may be unavailable.

## Validation

```sh
sh /tmp/forgemill-esxi-import.sh status
vim-cmd vmsvc/getallvms
```

Then connect ESXi to ForgeMill using its HTTPS API (normally TCP 443) and sync templates. Configure ESXi firewall rules independently.

## Security

Only import images from trusted sources. Using plain HTTP makes them vulnerable to network tampering; prefer HTTPS and independent publisher checksum verification when possible. Audit scripts before executing them as ESXi root. For reproducible deployments, download a pinned Git commit rather than the moving `main` branch.

## Project relationship

This directory contains the independent ESXi-side main-template source VM importer. The parent repository's `install-forgemill.bash` installs the **ForgeMill control panel on Ubuntu**, not on ESXi.
