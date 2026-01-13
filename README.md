# RASPI-BACKUP

This is a simple Bash script that creates full and incremental backups of Raspberry Pi's (or other Linux distributions). The original intention was that Raspberry Pi's come with ext4 by default, which does not offer snapshot capabilities like other filesystems. Furthermore, most of the tools I could find were designed for cases where you have physical access to the Raspberry Pi's and you plug the SD card into your own system to create an image backup.

Since I don't always have direct physical access, I wanted to enable remote backups, which then creates .img files. I wanted the .img file because, if an SD card breaks, I can simply take a new one, flash the image and put the SD card back in and the system is running again. I didn't want to deal with file permissions or anything like that.

## Core Ideas

- Create a bootable image including partition table and data.
- "Incremental" backups copy the previous backup and rsync only copies the changes. (This relieves the load especially for slow uploads to remote locations)
- Clients and schedules should be handled via a simple terminal UI similar to "raspi-config" (`whiptail`).
- Client configurations and job schedules are stored in a SQLite3 database.
- Backups are performed via SSH and Rsync (also via an SSH tunnel). This means the target can/must remain powered on and the SD card does not need to be removed.
- Backups from remote locations can be conveniently performed via VPN connections (which must be established beforehand and are not part of this). It only requires an SSH connection.

## Hauptfeatures

- Full image creation: replicate partition table, create filesystems, and copy partition contents into a single image file (.img).
- Incremental updates: mount the image locally and rsync changed files from the remote host into the mounted partitions.
- Per-client configuration: hostname/IP, user, password (or SSH key mode), and per-job excludes.
- Job scheduling: cron entries are automatically updated based on configured backup jobs.
- TUI management: add/edit/delete clients and backup jobs using `run.sh` interactive menu.
- Simple notification: optional POST of job log output to a configured notify URL.
- Individual and ad hoc runs are available by running the `job.sh`.

# Requirements

The scripts automatically check when they start whether everything they need is installed and install it if necessary.

- Bash or another POSIX compatible shell
- sqlite3
- rsync
- ssh (and if password-based SSH connections are desired `sshpass`)
- standard GNU coreutils (dd, losetup, mktemp, etc.) and filesystem tools (mkfs.ext4, mkfs.vfat, etc.)
- `whiptail` for the interactive TUI

# Quick Start

1. Download the scripts `job.sh` and `run.sh` or the entire repository.
2. Make the `*.sh` files executable with `chmod +x *.sh`.
3. Run the `run.sh` script:

```
./run.sh
```

This will create the SQLite3 database `backup_clients.db` (if it doesn't already exist) in the working directory.

Now you can add clients and jobs.

**Important:** Change the backup path in Settings. The default is `/tmp`. Backups would be deleted after a reboot.

Scheduled jobs can be found in `crontab -l` and you can also manually run the execute command to run the backups immediately.

## Navigating

To navigate, primarily use the arrow keys for movement, the Tab key to jump in context, and the Enter key to confirm. Furthermore, there are select options where you can select and deselect options with the space key.

## Start Individual Job

You can also operate the `job.sh` independently from the `run.sh` for a quick backup:

```
# sudo is required because the script manipulates loop devices and filesystems
sudo ./job.sh root@10.0.1.41 /dev/mmcblk0 /tmp/images/pi-latest.img /tmp --exclude=/proc/* --exclude=/sys/*
```

For more information, you can simply call the help:

```
./job.sh -h
# or
./job.sh --help
```

# Overview

There are several things to consider for backups. Especially permissions. But don't worry, I'll explain what's important.

## Automatic scheduling

When you add backup jobs via the TUI, the script will update `crontab` to run `run.sh --auto <job-id>` at the configured time. Ensure cron runs under a user with the right permissions (root for example).

## Configuration and storage

- All clients, backup jobs, excludes and settings are stored in `backup_clients.db` in the working directory.
- By default backups are stored under the configured `backup_path` (default `/tmp` so please change it). Each client gets its own directory.

## Using the Scripts in Production

- SSH key-based authentication is preferred, but password-based authentication is still supported.
- Keep the controller machine secure and restrict access to the database file.
- If you lose the database file or accidentally delete it, the backups are not gone and can still be used; you just need to reconfigure the configuration for further backups.

# Files

- `run.sh` — interactive management UI, DB initialization, cron updater and the main controller logic.
- `job.sh` — performs a single backup job: creates full image or updates an existing image incrementally.
- `backup_clients.db` — SQLite DB created by `run.sh` to store clients and jobs.

# Restore

To restore images, you just need to copy them to your PC, plug in a new SD card (or the old one) and perform a similar flash process as when setting up a Raspberry Pi, except you use your backup image file instead of the official image file.

Software with which I have successfully tested this:

- [Balena Etcher](https://etcher.balena.io/)
- [Raspberry Pi Imager](https://www.raspberrypi.com/software/)


# Contribution

Patches and improvements welcome: fork the repo and open a PR.

# License

See the repository `LICENSE` file for licensing information.