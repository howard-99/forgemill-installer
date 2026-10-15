# ForgeMill installer

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

The [ESXi importer v2.0](esxi-templates/import.sh) creates exactly three
**powered-off** VM sources on a fresh ESXi 7.x/8.x host, with clean display
names:

- `Template-Ubuntu-24.04`
- `Template-Rocky-9.8` (the operator-tested VMware-ready cloud image)
- `Template-MikroTik-CHR-7.23.7` (Legacy BIOS + IDE + keyboard setting)

The images must be hosted on your trusted image server. The default source
is `http://172.31.31.183/iso` and the default ESXi port group is
`VM Network`. **New ESXi 7 hosts have been observed hanging during
`wget` TLS connections to GitHub; a successful ping doesn't solve it.**
Use the [image-server publisher](esxi-templates/publish-to-image-server.sh)
once on your Proxmox/Linux HTTP server to stage the script at
`http://172.31.31.183/iso/forgemill-esxi-import.sh`. Then, from each
**ESXi SSH shell as root**:

```sh
wget -O /tmp/forgemill-esxi-import.sh http://172.31.31.183/iso/forgemill-esxi-import.sh && sh -n /tmp/forgemill-esxi-import.sh && sh /tmp/forgemill-esxi-import.sh check && sh /tmp/forgemill-esxi-import.sh all && sh /tmp/forgemill-esxi-import.sh status
```

**Compare the downloaded script SHA-256 to the trusted publisher's value
before running in production**; the convenient one-liner by itself
does not authenticate an HTTP script. Prefer a pinned audited commit and
independently verified OVA checksums. For staging commands, explicit
datastore, hash variables and limitations see the
[ESXi install instructions](esxi-templates/README.md).

**Important:** The standalone-ESXi fallback in unpatched upstream ForgeMill
may change the MikroTik IDE boot controller to SCSI. This repository also
contains an [opt-in source patch](patches/patch-forgemill-esxi-ide.py) and
[GitHub image build workflow](.github/workflows/build-fork-syncfix.yml)
to address the application side. The patched image is not installed
automatically; test CHR cloning, console input, and boot on each ESXi host
before production.


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
a reversible SQLite BEFORE DELETE trigger for one target that **skips only
deletes of templates referenced by declared SQLite foreign keys**. It does
not flag external templates as Factory-managed or delete deployment history.
Only use until the patched application is deployed.

```bash
curl -fsSL https://raw.githubusercontent.com/howard-99/forgemill-installer/main/fixes/repair-template-sync-fk.py -o /root/repair-template-sync-fk.py
sudo python3 /root/repair-template-sync-fk.py --target-id 1      # read-only
sudo docker stop --time 45 forgemill
sudo python3 /root/repair-template-sync-fk.py --apply --target-id 1
sudo docker start forgemill
```

The apply step creates a consistent timestamped backup in
`/opt/forgemill/backups` **before changing the database schema**, checks
integrity, and refuses to modify it if the container is running. Follow the
logs after trying Sync. After the patched application is proven working,
stop ForgeMill, run `sudo python3 /root/repair-template-sync-fk.py --remove
--target-id 1`, and start it again. Never delete your existing DB, disable
SQLite foreign keys, or modify the historical deployment IDs to force sync.

