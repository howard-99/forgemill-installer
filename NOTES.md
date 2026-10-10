# Operational notes

## Installation target

Use a fresh, booted Ubuntu **22.04, 24.04 or 26.04 LTS amd64** server with systemd and working internet access. The upstream ForgeMill image currently targets amd64. The installer requires root privileges and uses `/opt/forgemill` for persistent application storage.

After the installer reports a successful login, open its printed HTTPS URL and add your Proxmox VE, VMware vCenter or ESXi connection in ForgeMill. Configure those connections with your own hypervisor credentials.

## Release and maintenance policy

Every installer run queries the latest stable GitHub release and pulls the corresponding versioned image from GHCR. It runs the downloaded image by digest, so a reboot restarts the same installed image. Rerun `/opt/forgemill/install.bash` to upgrade deliberately, with deployments and template builds idle.

Keep Ubuntu and Docker security updates current. The health timer handles an unhealthy running container and respects intentional stops. It is not a replacement for monitoring free disk space, service availability or host failures.

## Storage and recovery

The installer creates no scheduled backups or database copies. Container logs rotate at three 10 MB files, apt download caches are cleaned, and a successful update removes the previously recorded image references without forcing removal of shared images.

Database records, template-build files and downloaded Packer plugins use real disk space. Keep the original encryption key with the database: saved hypervisor secrets depend on it. There is no automatic rollback after database migrations. The 2 GB memory and 2 CPU limits are ceilings, not reservations; heavy template work may require more resources or adjusted limits.

## Credentials and HTTPS

The initial admin password is generated on the server and printed only after successful authentication. The repository contains the generation logic, not an installed password or encryption key. The saved initial password becomes outdated if you change it in ForgeMill; rerunning the installer does not reset it.

HTTPS uses a generated self-signed certificate valid for ten years. Trust the certificate in your browser or install your own matching certificate and key. Default binding is all IPv4 interfaces on port 8443. Docker-published ports can bypass UFW; use a management interface binding and an upstream firewall to control access.

## Validation record — 2026-10-10

The implementation was checked against upstream configuration and release publishing for **v0.22.0**. Bash syntax and ShellCheck checks passed. Isolated, mocked flow tests covered the three supported Ubuntu release checks, Docker installation configuration, login verification, update ordering, secret preservation, changed passwords, interrupted setup, health recovery, intentional stops and failure cases.

Actual installation, reboot and load testing on Ubuntu VMs was unavailable in the Windows authoring environment. New upstream releases may introduce configuration changes; review their release notes before updating.
