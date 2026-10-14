# ForgeMill ESXi Main Template Importer

A standalone BusyBox/POSIX-shell importer for **VMware ESXi 7.x/8.x**. It prepares powered-off main-template source VMs for discovery by [ForgeMill](https://github.com/blink-zero/forgemill), without installing Python, Docker, or OVF Tool on the ESXi host.

This is the **v1.5 importer (v1.4 previously tested on ESXi 7.0.3; v1.5 requires host validation)** by the project operator. Other hardware, OVA variants and ESXi releases should be tested before production use.

## Images

| Mode | Powered-off VM name | Expected image filename |
| --- | --- | --- |
| `ubuntu` | `ubuntu-24.04-main-template` | `ubuntu-24.04-server-cloudimg-amd64.ova` |
| `chr` | `mikrotik-chr-7.24.5-main-template` | `chr-7.24.5.ova` |
| `rocky` | `rocky-9.8-main-template` | `rocky-9.8.ova` |
| `all` | All three | All three files |

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
sh /tmp/forgemill-esxi-import.sh chr
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

Optional settings: `BASE_URL`, `PORTGROUP`, `DATASTORE`, `MIN_FREE_GB`, `KEEP_SOURCE=1`, `KEEP_FAILED=1`, `WGET_NO_CHECK_CERT=1` (only for HTTPS OVA downloads; insecure). The initial GitHub script download requires its own `--no-check-certificate` flag on affected ESXi builds.

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
- `mikrotik`/`chr` images require RouterOS-specific first-boot setup and licensing.

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
