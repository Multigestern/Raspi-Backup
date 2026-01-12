# raspi-backup


A small set of Bash scripts to create full and incremental backups of Raspberry Pi (or other Linux) systems. The project focuses on creating full disk images (image files) and then keeping them up to date incrementally using rsync so you can quickly restore a failed SD card by flashing the latest image.

## Key ideas

- Create a bootable image of the remote device (partition table, filesystems and data).
- For subsequent runs, update only changed files within mounted partitions using rsync (incremental approach) to minimize transfer time and storage.
- Manage clients and scheduled backup jobs with a small TUI (`whiptail`).
- Store client configuration and job schedule metadata in an embedded SQLite database.
- Backups are performed remotely over SSH — the target device (Raspberry Pi) can remain powered on during the backup; no physical removal of the SD card is required.
- Backups also work over VPNs or SSH tunnels, so remote Pis (for example in a holiday home or at relatives) can be backed up as long as the controller machine can reach them via SSH.

## Main Features

- Full image creation: replicate partition table, create filesystems, and copy partition contents into a single image file (.img).
- Incremental updates: mount the image locally and rsync changed files from the remote host into the mounted partitions.
- Per-client configuration: hostname/IP, user, password (or SSH key mode), and per-job excludes.
- Job scheduling: cron entries are automatically updated based on configured backup jobs.
- TUI management: add/edit/delete clients and backup jobs using `run.sh` interactive menu.
- Simple notification: optional POST of job log output to a configured notify URL.
- Individual and ad hoc runs are available by running the `job.sh`.

# Requirements

- Bash (POSIX compatible shell)
- sqlite3
- rsync
- ssh (and optionally `sshpass` if password-based SSH is used)
- standard GNU coreutils (dd, losetup, mktemp, etc.) and filesystem tools (mkfs.ext4, mkfs.vfat, etc.)
- `whiptail` for the interactive TUI

# Quick start

1. Ensure requirements are installed on the machine that will run the backups (the controller machine).
2. Place the scripts on the controller and make them executable.

Run the interactive management UI:

```
./run.sh
```

This creates (if missing) a SQLite database `backup_clients.db` and allows you to add clients and jobs.

Run a single job manually (example):

```
# sudo is required because the script manipulates loop devices and filesystems
sudo ./job.sh root@10.0.1.41 /dev/mmcblk0 /tmp/images/pi-latest.img /tmp --exclude=/proc/* --exclude=/sys/*
```

## Automatic scheduling

When you add backup jobs via the TUI, the script will update `crontab` to run `run.sh --auto <job-id>` at the configured time. Ensure cron runs under a user with the right permissions.

## Configuration and storage

- All clients, backup jobs, excludes and settings are stored in `backup_clients.db` in the working directory.
- By default backups are stored under the configured `backup_path` (default `/tmp` so please change it). Each client gets its own directory.

## Using the scripts in production

- Prefer SSH key-based authentication for non-interactive cron jobs. Password-based backups are supported but require you to manage the key used to encrypt stored credentials if you choose to enable that feature.
- Keep the controller machine secure and restrict access to the database file.

# Files

- `run.sh` — interactive management UI, DB initialization, cron updater and the main controller logic.
- `job.sh` — performs a single backup job: creates full image or updates an existing image incrementally.
- `backup_clients.db` — SQLite DB created by `run.sh` to store clients and jobs.

# Examples

Add a client and job via the UI and test a single run with `--auto` (use an existing job id):

```bash
# run one job non-interactively (example job id 1)
bash run.sh --auto 1
```

# Contribution

Patches and improvements welcome: fork the repo and open a PR.

# License

See the repository `LICENSE` file for licensing information.

