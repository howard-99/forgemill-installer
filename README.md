# ForgeMill installer

A lightweight installer for [ForgeMill](https://github.com/blink-zero/forgemill/), with deliberate upgrades, persistent data and bounded logs.

See [operational notes](NOTES.md) for storage, credentials, maintenance and validation details, and [the changelog](CHANGELOG.md) for changes.

Copy `install-forgemill.bash` to a fresh **Ubuntu 22.04, 24.04 or 26.04 LTS x86-64 (amd64)** server, then run:

```bash
sudo bash install-forgemill.bash
```

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

It creates **no scheduled backups, database copies, source checkout, build toolchain, Compose stack or automatic ForgeMill upgrade job**. Persistent application data is required storage and can grow with usage. The installer never deletes databases, volumes, deployments, templates or arbitrary Docker images to free space. No installer can guarantee years of unattended operation: keep Ubuntu and Docker security updates current, monitor free disk space, and review ForgeMill release notes before updating. OS release upgrades remain your responsibility.

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
