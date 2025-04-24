This project provides a script designed to facilitate backups using rsync. 
It is specifically tailored for scheduling through Cron jobs and includes functionality to log and manage backup data within an SQLite3 database.

⚠️ WARNING: Passwords are stored in Cleartext in the Database.

# Features
1. Image-Based Backups: Create disk images of volumes for a complete snapshot of your data.

# QuickStart

Just run the `run.sh` file to start configuring your backups.
The database will be initialized when running the script the first time.

If you want to run just a single job manually you can run the `job.sh` script by itself.

