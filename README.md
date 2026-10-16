# ForgeMill installer

## Fresh ESXi — install all three templates (tested SSH commands)

On a **fresh VMware ESXi host**, enable SSH and paste these exact commands
as `root`. This is the sequence tested successfully on the operator's ESXi
environment; the VM source images must also be reachable by the host.

```sh
esxcli network firewall ruleset set -e true -r httpClient

wget --no-check-certificate -O /tmp/forgemill-esxi-import.sh https://raw.githubusercontent.com/howard-99/forgemill-installer/main/esxi-templates/import.sh

sh /tmp/forgemill-esxi-import.sh all
```

The `all` mode registers **three powered-off VMware template-source VMs**:

| Source VM | Image |
| --- | --- |
| `Template-Ubuntu-24.04` | Ubuntu Server 24.04 |
| `Template-Rocky-9.8` | Rocky Linux 9.8 |
| `Template-MikroTik-CHR-7.21rc6` | MikroTik CHR (working direct-ESXi console test) |

To install only one, use `sh /tmp/forgemill-esxi-import.sh ubuntu`,
`rocky` or `mikrotik`. To inspect the host or installed sources,
use `check` or `status` instead of `all`.

**Security and image-source notes:** `--no-check-certificate` disables
TLS certificate verification for the **installer-script download**; it
was needed for the tested ESXi configuration but does not authenticate the
download. Verify the downloaded script's SHA-256 against a trusted copy
before executing it in a sensitive environment. **This GitHub command
downloads the importer itself directly; the importer still downloads
the Ubuntu, Rocky and MikroTik images from its configured image server
(default `http://172.31.31.183/iso`).** The script's `BASE_URL` can be
overridden when images are mirrored somewhere else; it does not automatically
download those three disk images from GitHub.

For custom datastores, image checksums, network port groups and caveats,
see the [full ESXi template installation guide](esxi-templates/README.md).

---

A lightweight installer for [ForgeMill](https://github.com/blink-zero/forgemill/), with deliberate upgrades, persistent data and bounded logs.

See [operational notes](NOTES.md) for storage, credentials, maintenance and validation details, and [the changelog](CHANGELOG.md) for changes.

## One-command installation

On a fresh **Ubuntu 22.04, 24.04 or 26.04 LTS x86-64 (amd64)** server, paste this entire command into the terminal from your home directory:

```bash
sudo apt-get update && sudo apt-get install -y --no-install-recommends ca-certificates curl && curl -fsSL --retry 3 https://raw.githubusercontent.com/howard-99/forgemill-installer/main/install-forgemill.bash -o install-forgemill.bash && sudo bash install-forgemill.bash
```

This installs the download prerequisites, saves `install-forgemill.bash` in your current directory, and runs the full installer with administrator privileges. The installer handles Docker and all other required packages, downloads the newest stable ForgeMill release, starts the service, and prints the HTTPS URL and verified admin login credentials. No GitHub account or repository clone is needed. If Ubuntu asks for your sudo password, enter your Ubuntu account password.

The installer also saves a copy at `/opt/forgemill/install.bash` for later upgrades. If a download or prerequisite step fails, the command stops before running the installer; fix the reported issue and run the same command again.

If you already have the downloaded file, run `sudo bash install-forgemill.bash`.

The installer prints the HTTPS URL, username **admin**, and a randomly generated password after checking health and verifying login. Default address: **https://SERVER-IP:8443**. It generates a self-signed certificate valid for ten years; trust `/opt/forgemill/tls/server.crt` in your browser, or replace it and the corresponding `server.key` with your own certificate and rerun the installer. Use the printed server IP when trusting the generated certificate.

For a different port or a particular network interface:

```bash
sudo bash install-forgemill.bash --port 443 --bind 192.168.1.20
```

The default `0.0.0.0` binding listens on every IPv4 interface. Docker-published ports can bypass UFW rules. To limit access, use `--bind` for your management interface or loopback, and an upstream firewall when needed. Cloud firewalls must allow your chosen port before you can connect remotely. The printed IP is a local interface address; it does not discover a public NAT address or domain.

## What it installs

- Docker Engine from Docker's official stable Ubuntu repository when Docker is absent. An existing Docker installation is reused.
- The **newest stable GitHub release on every run**, using its versioned container image. It queries `/releases/latest`, excludes drafts/prereleases, strips the Git tag's `v` for the registry tag, pulls, and runs the resolved digest. It does not use the moving `latest` image tag, which upstream also publishes on pushes to `main`.
- One unprivileged container with a read-only root filesystem, dropped capabilities, a 2 GB memory ceiling, a 2 CPU ceiling, and small temporary filesystems. Limits are ceilings; resources are consumed as needed. Template builds still require disk and memory for ISOs and Packer plugins.
- Persistent SQLite data in `/opt/forgemill/data`. Authentication, encryption keys and initial password remain under `/opt/forgemill/secrets`.
- Native HTTPS without an extra reverse proxy or database server.
- Start after reboot and restart after process failure. A small systemd timer checks every two minutes and restarts a running container only after Docker reports it unhealthy. Intentional container stops are respected.
- Container log rotation at three 10 MB files. Installer temporary files and downloaded apt packages are cleaned up; after a successful update, only this install's previous image references are removed, without forcing removal of an image in use elsewhere.

The normal installer creates **no scheduled backups, database copies, source checkout, build toolchain, Compose stack or automatic ForgeMill upgrade job**. The optional FK workaround is separate and explicitly creates a pre-change database backup. Persistent application data is required storage and can grow with usage. The installer never deletes databases, volumes, deployments, templates or arbitrary Docker images to free space. No installer can guarantee years of unattended operation: keep Ubuntu and Docker security updates current, monitor free disk space, and review ForgeMill release notes before updating. OS release upgrades remain your responsibility.

## Update and manage

Run this when ForgeMill deployments and template builds are idle:

```bash
sudo bash /opt/forgemill/install.bash
```

Each run queries GitHub again and downloads the current stable release. It preserves data, encryption/JWT keys, TLS certificate and the selected port/address. The existing container is stopped only after the image download and configuration checks succeed. An update briefly interrupts access. ForgeMill applies database migrations on startup; there is no automatic rollback or backup copy. Internet access to Ubuntu repositories, Docker's repository, GitHub's API and GHCR is required. If a release image is still publishing, download fails while the old container stays running; rerun later.

To see the initial password again:

```bash
sudo cat /opt/forgemill/secrets/admin_password
```

If you changed the password in the app, that initial password file no longer describes the current password. The installer checks it on reruns and reports that you should use the existing password if authentication returns 401. It does not reset an account or generate new encryption keys over an existing database.

```bash
# Recent application logs
sudo docker logs --tail 50 forgemill

# Stop; the health timer leaves a stopped container alone
sudo docker stop --time 45 forgemill

# Start again
sudo docker start forgemill

# Health recovery timer
sudo systemctl status forgemill-health.timer
```

Keep `/opt/forgemill/data` and the original encryption key together. Deleting the encryption key makes saved encrypted connection credentials unreadable. This installer deliberately creates no recovery copies, as requested.

## Verification

Checked with Bash syntax validation and ShellCheck. The `tests/test_installer.py` harness redirects host paths to temporary fixtures and mocks package installation, Docker, networking and system services. It exercises the three Ubuntu release checks, Docker setup, login verification, update ordering and key preservation, interrupted setup, changed passwords, and failure cases. It does **not** perform real installations or prove runtime compatibility on Ubuntu VMs. Real Ubuntu installation/reboot/load testing was unavailable in the Windows authoring environment.

Sources: [ForgeMill README](https://github.com/blink-zero/forgemill/blob/main/README.md), [production configuration](https://github.com/blink-zero/forgemill/blob/main/docker-compose.prod.yml), [image publishing workflow](https://github.com/blink-zero/forgemill/blob/main/.github/workflows/docker-publish.yml), [Docker's Ubuntu instructions](https://docs.docker.com/engine/install/ubuntu/).

---

## Fresh ESXi host — three ready-to-import template sources

The [ESXi importer v2.3](esxi-templates/import.sh) installs **exactly
three powered-off** source VMs for ForgeMill:

- `Template-Ubuntu-24.04` — cloud OVA
- `Template-Rocky-9.8` — working VMware-ready OVA
- **`Template-MikroTik-CHR-7.21rc6`** — the Legacy BIOS **VMDK**
  that booted with a working keyboard in a direct ESXi test

CHR **7.23.7 has been removed from the default installer**. Existing
7.23.7 VMs are not removed or changed. CHR 7.21rc6 uses IDE 0:0,
virtual hardware 17 and the default virtual keyboard (no additional
PS/2/USB keyboard tweaks). The new source has a VMXNET3 NIC; a
ForgeMill-*deployed* clone still needs its own keyboard/boot test.

Use the **tested direct-GitHub commands at the top of this README** to
download the importer on a new ESXi host and install all three source VMs.
For sites where ESXi cannot access GitHub, the
[image-server publisher](esxi-templates/publish-to-image-server.sh) remains
an alternative way to distribute the script over a trusted LAN.

The default image sources are still the two OVAs and
`chr-7.21rc6-legacy-bios.vmdk` on `172.31.31.183/iso`, even when the
**installer script** was downloaded directly from GitHub. To change the
source, mirror all three files and set `BASE_URL`. In production, pin the
image checksums (including `CHR_721RC6_SHA256`) to values measured over
a trusted channel; plain HTTP does not authenticate these assets.

**Important:** The direct 7.21rc6 console test does not prove that an
unpatched ForgeMill standalone-ESXi clone will preserve IDE or accept
typing. The source-level [IDE cloning patch](patches/patch-forgemill-esxi-ide.py)
and [GHCR image build workflow](.github/workflows/build-fork-syncfix.yml)
are separate application-side fixes. Importing a template alone cannot
update your running ForgeMill container.

---

## ForgeMill ESXi template-sync foreign-key fix

**Diagnosis on ESXi-188 (2026-10-15):** The official ForgeMill release's
`TargetService.SyncTemplates` deletes unmanaged template rows before
re-inserting/updating the inventory. The deletion fails with SQLite FK error
787 when historical deployments reference those IDs. This affects existing
records such as `rocky-9.8-golden` and `mikrotik-chr-7.24.5-golden`.

This repository contains two remedies:

**Permanent application patches (opt-in image, not yet published):**
[patches/patch-forgemill-template-sync.py](patches/patch-forgemill-template-sync.py)
removes the unsafe deletion from upstream
`internal/service/target.go`. The
[IDE/keyboard patch](patches/patch-forgemill-esxi-ide.py) also attempts to
preserve the MikroTik controller and IRQ setting during standalone ESXi
fallback cloning. Both patches are included when building the patched image. The existing `INSERT ... ON CONFLICT
(target_id, moref) DO UPDATE` refreshes synchronized templates in place.
Template IDs and dependent history survive. **Trade-off:** this conservative
interim fix leaves stale templates visible until a separate, dependency-aware
pruning feature is developed.

To build the patched image in GitHub, open **Actions → Build patched
ForgeMill image (ESXi sync + CHR IDE fixes) → Run workflow**, and enter an
official ForgeMill release tag, e.g. `v0.21.0`, **matching the version you
intend to run**. This checks out the upstream tag, fails if the vulnerable
code doesn't match, applies the patch, and publishes:

```text
ghcr.io/howard-99/forgemill-syncfix:0.21.0
```

Version above is illustrative; the tag you choose determines the actual
image. Ensure the GHCR package is readable by the server (publish it or
authenticate Docker to GHCR), then on the Ubuntu ForgeMill host:

```bash
curl -fsSL https://raw.githubusercontent.com/howard-99/forgemill-installer/main/install-forgemill.bash -o /tmp/install-forgemill.bash
sudo bash /tmp/install-forgemill.bash --image ghcr.io/howard-99/forgemill-syncfix:0.21.0
```

The `--image` option is restricted to a pinned semver tag in this
repository's GHCR image, verified by registry digest, and saved in
`/opt/forgemill/settings.json`. Subsequent installer runs retain the chosen
image, rather than reverting silently to official releases.
`--official-image` explicitly returns to the upstream release channel.
**Building and publishing the image requires running the GitHub workflow;
editing the installer alone does not fix a live ForgeMill binary.** Never
run an installer upgrade while deployments are active, and take a separate
verified database/secrets backup first; application migrations aren't
automatically reversible.

**Immediate, temporary workaround for the current running release:**
[fixes/repair-template-sync-fk.py](fixes/repair-template-sync-fk.py) installs
an **all-target** SQLite `BEFORE DELETE` guard. It skips only deletion of
templates referenced by declared SQLite foreign keys. Unlike the earlier
single-target workaround, it protects ESXi-188, ESXi-192 and other future
targets. The script safely upgrades the older scoped guard if it exists.
It does not change the application binary, mark templates Factory-managed,
remove deployment history or discard existing templates.

Run on the **Ubuntu ForgeMill control-plane server** as root, not ESXi.
Do not modify the database while the container runs. First download the
script and examine the read-only output:

```bash
curl -fsSL https://raw.githubusercontent.com/howard-99/forgemill-installer/main/fixes/repair-template-sync-fk.py -o /root/repair-template-sync-fk.py
python3 -m py_compile /root/repair-template-sync-fk.py
sudo python3 /root/repair-template-sync-fk.py
```

Only when preflight reports `Integrity: ok; foreign_key_check: ok`, and
there are no deployments or builds in progress:

```bash
sudo docker stop --time 45 forgemill
sudo python3 /root/repair-template-sync-fk.py --apply
sudo docker start forgemill
sudo docker logs --since 5m --tail 100 forgemill
```

If apply fails, **restart the container before further troubleshooting**.
The change creates a verified, timestamped SQLite backup under
`/opt/forgemill/backups` before modifying schema and refuses to modify
the database unless Docker confirms ForgeMill is stopped. Retest
`Sync Templates` for your ESXi target.

**Permanent resolution requires building and installing the patched
ForgeMill application image** using the workflow above. A GitHub
repository commit or an ESXi-side template import does not update the
currently running container. After the permanent image is deployed,
sync is verified and a backup is retained, stop ForgeMill and run
`sudo python3 /root/repair-template-sync-fk.py --remove`, then restart.
Never delete history or disable SQLite foreign keys to force sync.

