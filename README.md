# Linux Init Scripts

This repository contains a collection of scripts for initializing and configuring Linux and Windows servers.

## Scripts

### System Backup

-   **`sys-backup-v3.sh`**: (Recommended) An intelligent, OS-aware backup script that uses `restic` and `rclone`. It automatically detects the Linux distribution (Debian, Ubuntu, Alpine, CentOS, etc.) to install dependencies. For efficiency and to save disk space, it streams MySQL and PostgreSQL database dumps directly to the backup destination. ClickHouse databases are backed up individually to minimize temporary local storage.
-   **`sys-backup-v2.sh`**: A simpler `restic` and `rclone` backup script. **Warning:** This version dumps all databases to a local temporary directory before starting the upload, which can consume significant disk space.

### System Configuration & Tweaks

-   **`linux-tweaks.sh`**: An interactive script to harden a new Linux server. It handles SSH key setup, disables password authentication, improves the `.bashrc` experience, installs common utility packages, and sets a custom MOTD.
-   **`debian-stripper.sh`**: Optimizes a Debian-based system for low-memory environments. It adds a swap file, limits `journald` memory usage, disables daily `apt` timers, and removes unnecessary packages.
-   **`firewall-hardened.sh`**: Configures `iptables` and `ip6tables` with a secure, default-drop policy. It allows essential traffic (loopback, established connections) and opens the Tailscale UDP port. It also includes instructions for persisting the rules.
-   **`init-samba.sh`**: Sets up a Samba server with a predefined configuration and restores user passwords from a backup `tdb` file fetched from a GitHub repository.

### Tailscale & DNS

-   **`magicDNS-daemon.sh`**: (For Linux) Creates a systemd timer to periodically run a script that updates `/etc/hosts` with all the peers from your Tailscale network, creating DNS entries for them (e.g., `hostname.your.domain` and `hostname`).
-   **`magicDNS-daemon-alpine.sh`**: A version of the MagicDNS daemon specifically for Alpine Linux.
-   **`install-tailscale-magicdns.ps1`**: (For Windows) The PowerShell equivalent of the MagicDNS daemon. It creates a scheduled task to keep the Windows hosts file updated with Tailscale peers.
-   **`update-tailscale-hosts.ps1`**: (For Windows) The PowerShell script that is deployed by `install-tailscale-magicdns.ps1` to perform the hosts file update.

### Utilities & Services

-   **`gdrive.sh`**: Sets up systemd services to mount different Google Drive paths (backups, hosts, netdata) to local directories using `rclone mount`.
-   **`battery-monitor.sh` / `battery-monitor-v2.sh` / `battery-monitor-v3.sh`**: A series of scripts for monitoring the battery on a Linux device (like a laptop or phone running a Linux environment). It creates systemd services to log battery stats and display the current battery percentage in the terminal title. Version 3 includes more intuitive icons.
-   **`scripts-watchdog.sh`**: A utility that creates a systemd service to watch the `/home/scripts` directory. It automatically makes any new file added to that directory executable (`chmod +x`).