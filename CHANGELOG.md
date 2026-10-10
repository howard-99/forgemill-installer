# Changelog

## 2026-10-10 — Public installation command

- Made the installer repository public so the script can be downloaded without GitHub authentication.
- Added one copy-and-paste Ubuntu command that installs download prerequisites, downloads the `.bash` file, and runs the full installer.
- Kept the downloaded installer available in the current directory and the installed copy under `/opt/forgemill` for future use.

## 2026-10-10 — Initial installer

- Added a Bash installer targeting fresh Ubuntu 22.04, 24.04 and 26.04 LTS amd64 servers.
- Resolve and download the newest stable ForgeMill release on every run.
- Install Docker Engine as needed, run one hardened container and preserve SQLite data and encryption keys.
- Generate native HTTPS configuration and verify the generated admin login before printing credentials.
- Configure restart after reboot, bounded container logs and periodic recovery of an unhealthy running container.
- Preserve existing data on reruns; clean installer temporary files and previous managed image references after successful updates.
- Include usage instructions, maintenance/storage notes and an isolated installer-flow test harness.
- Create no scheduled backups or automatic application-upgrade jobs.
