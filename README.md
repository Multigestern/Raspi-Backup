This project provides a script designed to facilitate backups using disk images and Rsync. 
It is specifically tailored for scheduling through Cron jobs and includes functionality to log and manage backup data within an SQLite3 database.

⚠️ WARNING: Passwords are stored in Cleartext in the Database.

# Features
1. Image-Based Backups: Create disk images of volumes for a complete snapshot of your data.
2. Rsync-Based Backups: Use Rsync for efficient, incremental backups of files and directories.
