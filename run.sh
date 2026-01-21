#!/usr/bin/env bash

# Color definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

FULLPATH="$(realpath "$0")"
SCRIPT_DIR="$(dirname "$FULLPATH")"
DB_FILE="$SCRIPT_DIR/backup_clients.db"

# Encryption helpers
encrypt_password() {
    if [ -z "$1" ]; then
        echo ""
        return 0
    fi
    if [ -z "$RBACKUP_MASTER_KEY" ]; then
        return 1
    fi
    printf '%s' "$1" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass env:RBACKUP_MASTER_KEY -A 2>/dev/null
}

decrypt_password() {
    if [ -z "$1" ]; then
        echo ""
        return 0
    fi
    echo -n "$1" | openssl enc -d -aes-256-cbc -a -A -pbkdf2 -pass env:RBACKUP_MASTER_KEY 2>/dev/null
}

generate_random_master_key() {
    openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64
}

get_machine_uuid() {
    if command -v ioreg >/dev/null 2>&1; then
        uuid=$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F\" '/IOPlatformUUID/ {print $4; exit}')
    fi
    if [ -z "$uuid" ]; then
        uuid=$(hostname)
    fi
    printf '%s' "$uuid"
}

derive_wrap_key() {
    local uuid
    uuid=$(get_machine_uuid)
    local wrap_key
    if command -v sha256sum >/dev/null 2>&1; then
        wrap_key=$(printf '%s' "$uuid" | sha256sum | awk '{print $1}')
    else
        wrap_key=$(printf '%s' "$uuid" | shasum -a 256 | awk '{print $1}')
    fi
    printf '%s' "$wrap_key"
}

wrap_master_key() {
    if [ -z "$1" ]; then
        echo ""
        return 0
    fi
    local wrap
    wrap=$(derive_wrap_key)
    echo -n "$1" | openssl enc -aes-256-cbc -a -salt -pbkdf2 -pass pass:"$wrap" -A 2>/dev/null
}

unwrap_master_key() {
    if [ -z "$1" ]; then
        echo ""
        return 0
    fi
    local wrap
    wrap=$(derive_wrap_key)
    echo -n "$1" | openssl enc -d -aes-256-cbc -a -A -pbkdf2 -pass pass:"$wrap" 2>/dev/null
}

load_master_key_from_db() {
    if [ -n "$RBACKUP_MASTER_KEY" ]; then
        return 0
    fi
    if [ ! -f "$DB_FILE" ]; then
        return 0
    fi
    
    ENC_KEY=$(sqlite3 "$DB_FILE" "SELECT master_key_encrypted FROM settings LIMIT 1;" 2>/dev/null)
    
    if [ -n "$ENC_KEY" ]; then
        DECRYPTED=$(unwrap_master_key "$ENC_KEY")
        if [ -n "$DECRYPTED" ]; then
            export RBACKUP_MASTER_KEY="$DECRYPTED"
            return 0
        else
            return 1
        fi
    else
        generate_and_store_master_key
        return $?
    fi
}

generate_and_store_master_key() {
    RANDOM_KEY=$(generate_random_master_key)
    if [ -z "$RANDOM_KEY" ]; then
        return 1
    fi
    if store_master_key_to_db "$RANDOM_KEY"; then
        export RBACKUP_MASTER_KEY="$RANDOM_KEY"
        return 0
    else
        return 1
    fi
}

store_master_key_to_db() {
    local plaintext="$1"
    if [ -z "$plaintext" ]; then
        sqlite3 "$DB_FILE" "UPDATE settings SET master_key_encrypted = '' WHERE id = 1;" 2>/dev/null
        return 0
    fi
    local wrapped
    wrapped=$(wrap_master_key "$plaintext")
    if [ -z "$wrapped" ]; then
        return 1
    fi
    sqlite3 "$DB_FILE" "UPDATE settings SET master_key_encrypted = '$wrapped' WHERE id = 1;" 2>/dev/null
    return 0
}

# Initialize the SQLite database
initialize_db() {
    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT UNIQUE NOT NULL,
    username TEXT NOT NULL,
    password TEXT,
    ssh_key BOOLEAN DEFAULT 0
);
EOF

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS backup_jobs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    client_id INTEGER NOT NULL,
    disk TEXT NOT NULL,
    max_backups INTEGER NOT NULL,
    schedule TEXT NOT NULL, -- 'HH:MM' or auto-generated
    weekdays TEXT DEFAULT 'Mon,Tue,Wed,Thu,Fri',
    FOREIGN KEY (client_id) REFERENCES clients(id)
);
EOF

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS settings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    backup_path TEXT NOT NULL,
    notify_url TEXT NOT NULL,
    log_path TEXT DEFAULT '/tmp',
    master_key_encrypted TEXT
);
INSERT OR IGNORE INTO settings (id, backup_path, notify_url, log_path, master_key_encrypted) VALUES (1, '/tmp', 'https://example.com', '/tmp', '');
EOF

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS global_excludes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    exclude_path TEXT NOT NULL UNIQUE
);
INSERT OR IGNORE INTO global_excludes (id, exclude_path) VALUES (1, '/proc/*');
INSERT OR IGNORE INTO global_excludes (id, exclude_path) VALUES (2, '/sys/*');
INSERT OR IGNORE INTO global_excludes (id, exclude_path) VALUES (3, '/dev/*');
INSERT OR IGNORE INTO global_excludes (id, exclude_path) VALUES (4, '/run/*');
EOF

    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS job_excludes (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    job_id INTEGER NOT NULL,
    exclude_path TEXT NOT NULL,
    FOREIGN KEY (job_id) REFERENCES backup_jobs(id)
);
EOF
}

# Display the main menu
main_menu() {
    while true; do
        CHOICE=$(whiptail --title "Main Menu" --menu "Choose an option" --cancel-button "Exit" 25 120 16 \
            "List Clients" "List all registered backup clients." \
            "Backup Jobs" "Manage backup jobs for clients." \
            "Settings" "Configure backup settings." \
            "Help" "Show script help." 3>&1 1>&2 2>&3)

        if [ $? -ne 0 ]; then
            exit 0
        fi

        case $CHOICE in
            "List Clients")
                list_clients
                ;;
            "Backup Jobs")
                backup_jobs
                ;;
            "Settings")
                settings_menu
                ;;
            "Help")
                show_help
                ;;
        esac
    done
}

# Show help dialog
show_help() {
    whiptail --title "Help" --msgbox "This script assists with image-based and incremental file-based backups of Linux servers. Originally designed for Raspberry Pi devices.

To begin, register a client by providing a name and IP address. Connections are made via SSH/Rsync. Specify a username with the necessary privileges.

You may either set a password (stored encrypted in the database) or leave the password blank and use SSH key authentication (has to be preconfigured).

Important settings:
- Backup Path: Location where backups are stored, organized by CLIENT_NAME/BACKUPFILE.+
- Log Paht: Location where log files are saved. Default is /tmp.
- Global Exclusions: Paths excluded from all Rsync backups.

After registering a client, create a job for it." 24 80
}

##############################################
############## Client Functions ##############
##############################################

# Liste existing clients
list_clients() {
    CLIENTS=$(sqlite3 "$DB_FILE" <<EOF
SELECT id, name, ip FROM clients;
EOF
)

    if [ -z "$CLIENTS" ]; then
        if whiptail --title "List Clients" --yesno "No clients found. Add a new client?" 10 60; then
            add_client
            return
        else
            return
        fi
    fi

    MENU_ENTRIES=()
    while IFS='|' read -r ID NAME IP; do
        if [ -n "$ID" ] && [ -n "$NAME" ]; then
            MENU_ENTRIES+=("$ID" "$NAME ($IP)")
        fi
    done <<< "$CLIENTS"

    SELECTED=$(whiptail --title "List Clients" --menu "Select a client to edit or delete:" --cancel-button "Back" 25 120 16 "${MENU_ENTRIES[@]}" "Add Client" "Create a new client" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    if [ "$SELECTED" == "Add Client" ]; then
        add_client
        return
    fi

    ACTION=$(whiptail --title "Client Action" --menu "What do you want to do with this client?" --cancel-button "Back" 15 60 4 \
        "Edit" "Modify client details." \
        "Delete" "Remove client from database." 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    case $ACTION in
        "Edit")
            edit_client "$SELECTED"
            ;;
        "Delete")
            delete_client "$SELECTED"
            ;;
    esac

    list_clients
}

add_client() {
    NAME=$(whiptail --title "Add Client" --inputbox "Enter client name:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    while true; do
        NEW_IP=$(whiptail --title "Add Client" --inputbox "Enter IP address:" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if is_valid_ip "$NEW_IP"; then
            break
        else
            whiptail --title "Invalid IP" --msgbox "Please enter a valid IPv4 address." 10 60
        fi
    done


    USERNAME=$(whiptail --title "Add Client" --inputbox "Enter username:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    PASSWORD=""
    while true; do
        PASSWORD=$(whiptail --title "Add Client" --passwordbox "Enter password (leave blank for SSH key):" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [ -n "$PASSWORD" ]; then
            CONFIRM=$(whiptail --title "Confirm Password" --passwordbox "Re-enter password:" 10 60 3>&1 1>&2 2>&3)

            if [ "$PASSWORD" = "$CONFIRM" ]; then
                break
            else
                whiptail --title "Mismatch" --msgbox "Passwords do not match." 10 60
            fi
        else
            break
        fi
    done

    if [ -n "$PASSWORD" ]; then
        USE_SSH_KEY=0
        if [ -z "$RBACKUP_MASTER_KEY" ]; then
            whiptail --title "Encryption Key Missing" --msgbox "RBACKUP_MASTER_KEY is not set. Set this environment variable to securely store passwords, or leave the password blank to use SSH key authentication." 12 70
            return
        fi
        ENC_PASS=$(encrypt_password "$PASSWORD")
        if [ $? -ne 0 ] || [ -z "$ENC_PASS" ]; then
            whiptail --title "Encryption Failed" --msgbox "Failed to encrypt password. Check that 'openssl' is available and RBACKUP_MASTER_KEY is correct." 12 70
            return
        fi
        STORED_PASSWORD="ENC:$ENC_PASS"
    else
        USE_SSH_KEY=1
        STORED_PASSWORD=""
    fi

    sqlite3 "$DB_FILE" <<EOF
INSERT INTO clients (name, ip, username, password, ssh_key)
VALUES ("$NAME", "$NEW_IP", "$USERNAME", "$STORED_PASSWORD", $USE_SSH_KEY);
EOF

    whiptail --title "Add Client" --msgbox "Client added successfully." 10 60
}

edit_client() {
    CLIENT_ID="$1"
    CLIENT_DATA=$(sqlite3 "$DB_FILE" "SELECT name, ip, username, password, ssh_key FROM clients WHERE id = $CLIENT_ID;")
    IFS="|" read -r NAME IP USERNAME PASSWORD SSH_KEY <<<"$CLIENT_DATA"

    NEW_NAME=$(whiptail --title "Edit Client" --inputbox "Enter client name:" 10 60 "$NAME" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    while true; do
        NEW_IP=$(whiptail --title "Edit Client" --inputbox "Enter IP address:" 10 60 "$IP" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if is_valid_ip "$NEW_IP"; then
            break
        else
            whiptail --title "Invalid IP" --msgbox "The entered IP address is not valid. Please enter a valid IPv4 address." 10 60
        fi
    done

    NEW_USERNAME=$(whiptail --title "Edit Client" --inputbox "Enter username:" 10 60 "$USERNAME" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    NEW_PASSWORD=""
    while true; do
        NEW_PASSWORD=$(whiptail --title "Edit Client" --passwordbox "Enter new password (leave blank to keep current password):" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [ -n "$NEW_PASSWORD" ]; then
            CONFIRM_PASSWORD=$(whiptail --title "Edit Client" --passwordbox "Confirm new password:" 10 60 3>&1 1>&2 2>&3)
            [ $? -ne 0 ] && return

            if [ "$NEW_PASSWORD" = "$CONFIRM_PASSWORD" ]; then
                break
            else
                whiptail --title "Edit Client" --msgbox "Passwords do not match. Please try again." 10 60
            fi
        else
            NEW_PASSWORD="$PASSWORD"
            break
        fi
    done

    if [ -n "$NEW_PASSWORD" ] && [ "$NEW_PASSWORD" != "$PASSWORD" ]; then
        if [ -z "$RBACKUP_MASTER_KEY" ]; then
            whiptail --title "Encryption Key Missing" --msgbox "RBACKUP_MASTER_KEY is not set. Set this environment variable to securely store passwords." 12 70
            return
        fi
        ENC_PASS=$(encrypt_password "$NEW_PASSWORD")
        if [ $? -ne 0 ] || [ -z "$ENC_PASS" ]; then
            whiptail --title "Encryption Failed" --msgbox "Failed to encrypt password. Check that 'openssl' is available and RBACKUP_MASTER_KEY is correct." 12 70
            return
        fi
        STORED_PASSWORD="ENC:$ENC_PASS"
        USE_SSH_KEY=0
    else
        STORED_PASSWORD="$PASSWORD"
        USE_SSH_KEY=$SSH_KEY
    fi

    sqlite3 "$DB_FILE" <<EOF
UPDATE clients
SET name = "$NEW_NAME",
    ip = "$NEW_IP",
    username = "$NEW_USERNAME",
    password = "$STORED_PASSWORD",
    ssh_key = $USE_SSH_KEY
WHERE id = $CLIENT_ID;
EOF

    whiptail --title "Edit Client" --msgbox "Client updated successfully." 10 60
}

delete_client() {
    CLIENT_ID="$1"
    CLIENT_NAME=$(sqlite3 "$DB_FILE" "SELECT name FROM clients WHERE id = $CLIENT_ID;")

    if whiptail --title "Delete Client" --yesno "Are you sure you want to delete the client '$CLIENT_NAME'?" 10 60; then
        sqlite3 "$DB_FILE" "DELETE FROM backup_jobs WHERE client_id = $CLIENT_ID;"
        sqlite3 "$DB_FILE" "DELETE FROM clients WHERE id = $CLIENT_ID;"
        update_cron
        whiptail --title "Delete Client" --msgbox "Client '$CLIENT_NAME' deleted successfully." 10 60
    else
        whiptail --title "Delete Client" --msgbox "Deletion cancelled." 10 60
    fi
}

#########################################
############## Backup Jobs ##############
#########################################

backup_jobs() {
    CLIENTS=$(sqlite3 "$DB_FILE" <<'SQL'
SELECT id, name, ip FROM clients;
SQL
)

    if [ -z "$CLIENTS" ]; then
        whiptail --title "Backup Jobs" --msgbox "No clients found. Please add clients first." 10 60
        return
    fi

    MENU_ENTRIES=()
    while IFS='|' read -r ID NAME IP; do
        if [ -n "$ID" ] && [ -n "$NAME" ]; then
            MENU_ENTRIES+=("$ID" "$NAME ($IP)")
        fi
    done <<< "$CLIENTS"

    SELECTED_CLIENT=$(whiptail --title "Backup Jobs" --menu "Select a client to view and manage its backup jobs:" --cancel-button "Back" 25 120 16 "${MENU_ENTRIES[@]}" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    CLIENT_NAME=$(sqlite3 "$DB_FILE" "SELECT name FROM clients WHERE id = $SELECTED_CLIENT;")
    JOBS=$(sqlite3 "$DB_FILE" <<'SQL'
SELECT id, schedule, max_backups, weekdays FROM backup_jobs WHERE client_id = $SELECTED_CLIENT;
SQL
)

    if [ -z "$JOBS" ]; then
        if whiptail --title "Manage Jobs" --yesno "No backup jobs found for client '$CLIENT_NAME'. Would you like to add one?" 10 60; then
            add_job "$SELECTED_CLIENT"
        else
            backup_jobs
        fi
    else
        JOBS_MENU=()
        while IFS='|' read -r JOB_ID JOB_SCHEDULE JOB_MAX_BACKUPS WEEKDAYS; do
            if [ -n "$JOB_ID" ]; then
                JOBS_MENU+=("$JOB_ID" "Time: $JOB_SCHEDULE at $WEEKDAYS | Retention: $JOB_MAX_BACKUPS backup(s)")
            fi
        done <<< "$JOBS"

        SELECTED_ACTION=$(whiptail --title "Manage Jobs" --menu "Manage backup jobs for client '$CLIENT_NAME':" --cancel-button "Back" 25 120 16 "${JOBS_MENU[@]}" "Add Job" "Create a new backup job for this client" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [ "$SELECTED_ACTION" == "Add Job" ]; then
            add_job "$SELECTED_CLIENT"
        else
            manage_job_action "$SELECTED_CLIENT" "$SELECTED_ACTION"
        fi
    fi
}

manage_job_action() {
    CLIENT_ID="$1"
    JOB_ID="$2"

    if [[ "$JOB_ID" == "Add Job" ]]; then
        add_job "$CLIENT_ID"
        return
    fi

    JOB_DETAILS=$(sqlite3 "$DB_FILE" "SELECT disk, max_backups, schedule FROM backup_jobs WHERE id = $JOB_ID;")
    IFS="|" read -r DISK MAX_BACKUPS SCHEDULE <<< "$JOB_DETAILS"

    MENU_OPTIONS=(
        "Edit" "Edit the job details."
        "Delete" "Delete the job from the database."
    )

    ACTION=$(whiptail --title "Job Action" --menu "What do you want to do with this job?" --cancel-button "Back" 15 80 4 "${MENU_OPTIONS[@]}" 3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && return

    case $ACTION in
        "Edit")
            edit_job "$JOB_ID" "$DISK" "$MAX_BACKUPS" "$SCHEDULE"
            ;;
        "Job Excludes")
            manage_job_excludes "$JOB_ID"
            ;;
        "Delete")
            delete_job "$JOB_ID"
            ;;
    esac
}

add_job() {
    CLIENT_ID="$1"

    DISK=$(whiptail --inputbox "Enter disk you want to backup (e.g. sda):" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    WEEKDAYS=$(whiptail --title "Select Weekdays" --checklist "Choose days for backup:" 15 80 7 \
        "Mon" "Monday" ON \
        "Tue" "Tuesday" ON \
        "Wed" "Wednesday" ON \
        "Thu" "Thursday" ON \
        "Fri" "Friday" ON \
        "Sat" "Saturday" OFF \
        "Sun" "Sunday" OFF 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    WEEKDAYS=$(echo "$WEEKDAYS" | tr -d '"')

    while true; do
        SCHEDULE=$(whiptail --inputbox "Enter the schedule time (HH:MM):" 10 60 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [[ "$SCHEDULE" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
            break
        else
            whiptail --msgbox "Invalid time format. Please use HH:MM (24-hour format)." 10 60
        fi
    done

    RETENTION=$(whiptail --title "Retention" --inputbox "How many backups do you want to keep?" 15 80 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    sqlite3 "$DB_FILE" <<EOF
INSERT INTO backup_jobs (client_id, disk, schedule, max_backups, weekdays)
VALUES ($CLIENT_ID, "$DISK", "$SCHEDULE", $RETENTION, "$WEEKDAYS");
EOF

    update_cron

    whiptail --title "Add Backup Job" --msgbox "Backup job added successfully!" 10 60
}

edit_job() {
    JOB_ID="$1"
    DISK="$2"
    MAX_BACKUPS="$3"
    SCHEDULE="$4"
    WEEKDAYS=$(sqlite3 "$DB_FILE" "SELECT weekdays FROM backup_jobs WHERE id = $JOB_ID;")

    DISK=$(whiptail --inputbox "Enter disk you want to backup (e.g. sda):" 10 60 "$DISK" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    NEW_WEEKDAYS=$(whiptail --title "Edit Weekdays" --checklist "Update days for backup:" 15 80 7 \
        "Mon" "Monday" $(echo "$WEEKDAYS" | grep -q "Mon" && echo ON || echo OFF) \
        "Tue" "Tuesday" $(echo "$WEEKDAYS" | grep -q "Tue" && echo ON || echo OFF) \
        "Wed" "Wednesday" $(echo "$WEEKDAYS" | grep -q "Wed" && echo ON || echo OFF) \
        "Thu" "Thursday" $(echo "$WEEKDAYS" | grep -q "Thu" && echo ON || echo OFF) \
        "Fri" "Friday" $(echo "$WEEKDAYS" | grep -q "Fri" && echo ON || echo OFF) \
        "Sat" "Saturday" $(echo "$WEEKDAYS" | grep -q "Sat" && echo ON || echo OFF) \
        "Sun" "Sunday" $(echo "$WEEKDAYS" | grep -q "Sun" && echo ON || echo OFF) 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    NEW_WEEKDAYS=$(echo "$NEW_WEEKDAYS" | tr -d '"')

    while true; do
        SCHEDULE=$(whiptail --inputbox "Enter the schedule time (HH:MM):" 10 60 "$SCHEDULE" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [[ "$SCHEDULE" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
            break
        else
            whiptail --msgbox "Invalid time format. Please use HH:MM (24-hour format)." 10 60
        fi
    done
    [ $? -ne 0 ] && return

    RETENTION=$(whiptail --title "Retention" --inputbox "How many backups do you want to keep?" 15 80 "$MAX_BACKUPS" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    sqlite3 "$DB_FILE" <<EOF
UPDATE backup_jobs
SET max_backups = $RETENTION,
    schedule = "$SCHEDULE",
    weekdays = "$NEW_WEEKDAYS"
WHERE id = $JOB_ID;
EOF

    update_cron

    whiptail --title "Edit Job" --msgbox "Backup job updated successfully!" 10 60
}

delete_job() {
    JOB_ID="$1"

    if whiptail --title "Delete Job" --yesno "Are you sure you want to delete this job?" 10 60; then
        sqlite3 "$DB_FILE" "DELETE FROM backup_jobs WHERE id = $JOB_ID;"
        update_cron

        if [ $? -eq 0 ]; then
            whiptail --title "Delete Job" --msgbox "Backup job deleted successfully." 10 60
        else
            whiptail --title "Delete Job" --msgbox "Failed to delete the backup job. Please try again." 10 60
        fi
    else
        whiptail --title "Delete Job" --msgbox "Deletion cancelled." 10 60
    fi
}

manage_job_excludes() {
    JOB_ID="$1"

    while true; do
        EXCLUDES=$(sqlite3 "$DB_FILE" "SELECT id, exclude_path FROM job_excludes WHERE job_id = $JOB_ID;")
        if [ -z "$EXCLUDES" ]; then
            if whiptail --title "Job Excludes" --yesno "No excludes found for this job. Would you like to add one?" 10 60; then
                add_job_exclude "$JOB_ID"
            else
                return
            fi
        else
            MENU_ENTRIES=()
            while IFS="|" read -r ID EXCLUDE_PATH; do
                MENU_ENTRIES+=("$ID" "$EXCLUDE_PATH")
            done <<< "$EXCLUDES"

            CHOICE=$(whiptail --title "Job Excludes" --menu "Manage excludes for job ID $JOB_ID:" --cancel-button "Back" 25 100 16 \
                "${MENU_ENTRIES[@]}" \
                "Add" "Add a new exclude path" 3>&1 1>&2 2>&3)

            [ $? -ne 0 ] && return

            if [ "$CHOICE" == "Add" ]; then
                add_job_exclude "$JOB_ID"
            else
                manage_job_exclude_action "$CHOICE"
            fi
        fi
    done
}

add_job_exclude() {
    JOB_ID="$1"

    EXCLUDE_PATH=$(whiptail --title "Add Job Exclude" --inputbox "Enter the path to exclude for this job:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO job_excludes (job_id, exclude_path) VALUES ($JOB_ID, '$EXCLUDE_PATH');"

    whiptail --title "Add Job Exclude" --msgbox "Exclude added successfully for job $JOB_ID." 10 60
}

manage_job_exclude_action() {
    EXCLUDE_ID="$1"

    ACTION=$(whiptail --title "Job Exclude Action" --menu "Choose an action:" --cancel-button "Back" 15 60 4 \
        "Delete" "Remove this exclude path" 3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && return

    if [ "$ACTION" == "Delete" ]; then
        sqlite3 "$DB_FILE" "DELETE FROM job_excludes WHERE id = $EXCLUDE_ID;"
        whiptail --title "Job Exclude" --msgbox "Exclude path removed successfully." 10 60
    fi
}


######################################
############## Settings ##############
######################################

settings_menu() {
    while true; do
        CHOICE=$(whiptail --title "Settings" --menu "Choose an option" --cancel-button "Back" 25 120 16 \
            "Backup Path" "Set the Path, where Backups should be stored." \
            "Log Path" "Set the Path, where Log files should be stored." \
            "Notification URL" "Set the URL which should recieve a POST if a Backups has errors." \
            "Global Exclusions" "Manage Exclusions for the Rsync Backup." 3>&1 1>&2 2>&3)

        [ $? -ne 0 ] && return

        case $CHOICE in
            "Backup Path")
                backup_path
                ;;
            "Log Path")
                log_path
                ;;
            "Notification URL")
                notification_url
                ;;
            "Global Exclusions")
                manage_global_excludes
                ;;
        esac
    done
}

backup_path() {
    BACKUP_PATH=$(sqlite3 "$DB_FILE" "SELECT backup_path FROM settings LIMIT 1;")
    if [ -z "$BACKUP_PATH" ]; then
        sqlite3 "$DB_FILE" "INSERT INTO settings (backup_path) VALUES ('/tmp');"
        BACKUP_PATH="/tmp"
    fi

    while true; do
        BACKUP_PATH=$(whiptail --title "Settings" --inputbox "Enter the backup path:" 10 60 "$BACKUP_PATH" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [ -d "$BACKUP_PATH" ]; then
            break
        else
            if whiptail --title "Invalid Path" --yesno "The specified path does not exist. \nShould "$BACKUP_PATH" be created?" 10 60; then
                mkdir -p $BACKUP_PATH
            fi
        fi
    done

    sqlite3 "$DB_FILE" <<EOF
UPDATE settings
SET backup_path = "$BACKUP_PATH";
EOF

    whiptail --title "Settings" --msgbox "Settings updated successfully." 10 60
}

log_path() {
    LOG_PATH=$(sqlite3 "$DB_FILE" "SELECT log_path FROM settings LIMIT 1;")
    if [ -z "$LOG_PATH" ]; then
        sqlite3 "$DB_FILE" "INSERT INTO settings (log_path) VALUES ('/tmp');"
        LOG_PATH="/tmp"
    fi

    while true; do
        LOG_PATH=$(whiptail --title "Settings" --inputbox "Enter the log path:" 10 60 "$LOG_PATH" 3>&1 1>&2 2>&3)
        [ $? -ne 0 ] && return

        if [ -d "$LOG_PATH" ]; then
            break
        else
            if whiptail --title "Invalid Path" --yesno "The specified path does not exist. \nShould \"$LOG_PATH\" be created?" 10 60; then
                mkdir -p "$LOG_PATH"
            fi
        fi
    done

    sqlite3 "$DB_FILE" <<EOF
UPDATE settings
SET log_path = "$LOG_PATH";
EOF

    update_cron

    whiptail --title "Settings" --msgbox "Settings updated successfully. Cron jobs have been updated." 10 60
}

notification_url() {
    NOTIFICATION_URL=$(sqlite3 "$DB_FILE" "SELECT notify_url FROM settings LIMIT 1;")
    if [ -z "$NOTIFICATION_URL" ]; then
        sqlite3 "$DB_FILE" "INSERT INTO settings (notify_url) VALUES ('https://example.com');"
        NOTIFICATION_URL=""
    fi

    NOTIFICATION_URL=$(whiptail --title "Settings" --inputbox "Enter the notification URL:" 10 60 "$NOTIFICATION_URL" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    sqlite3 "$DB_FILE" <<EOF
UPDATE settings
SET notify_url = "$NOTIFICATION_URL";
EOF

    whiptail --title "Settings" --msgbox "Settings updated successfully." 10 60
}
manage_global_excludes() {

    while true; do
        EXCLUDES=$(sqlite3 "$DB_FILE" "SELECT id, exclude_path FROM global_excludes;")
        if [ -z "$EXCLUDES" ]; then
            if whiptail --title "Global Excludes" --yesno "No global excludes found. Would you like to add one?" 10 60; then
                add_global_exclude
            else
                return
            fi
        else
            MENU_ENTRIES=()
            while IFS="|" read -r ID EXCLUDE_PATH; do
                MENU_ENTRIES+=("$ID" "$EXCLUDE_PATH")
            done <<< "$EXCLUDES"

            CHOICE=$(whiptail --title "Global Excludes" --menu "Manage global excludes:" --cancel-button "Back" 25 120 16 \
                "${MENU_ENTRIES[@]}" \
                "Add" "Add a new exclude path" 3>&1 1>&2 2>&3)

            [ $? -ne 0 ] && return

            if [ "$CHOICE" == "Add" ]; then
                add_global_exclude
            else
                manage_global_exclude_action "$CHOICE"
            fi
        fi
    done
}


add_global_exclude() {
    EXCLUDE_PATH=$(whiptail --title "Add Global Exclude" --inputbox "Enter the path to exclude:" 10 60 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && return

    sqlite3 "$DB_FILE" <<EOF
INSERT OR IGNORE INTO global_excludes (exclude_path)
VALUES ("$EXCLUDE_PATH");
EOF

    whiptail --title "Add Global Exclude" --msgbox "Global exclude added successfully." 10 60
}

manage_global_exclude_action() {
    EXCLUDE_ID="$1"

    ACTION=$(whiptail --title "Global Exclude Action" --menu "Choose an action:" --cancel-button "Back" 15 60 4 \
        "Delete" "Remove this exclude path" 3>&1 1>&2 2>&3)

    [ $? -ne 0 ] && return

    if [ "$ACTION" == "Delete" ]; then
        sqlite3 "$DB_FILE" "DELETE FROM global_excludes WHERE id = $EXCLUDE_ID;"
        whiptail --title "Global Exclude" --msgbox "Exclude path removed successfully." 10 60
    fi
}


#####################################
############## Helpers ##############
#####################################

is_valid_ip() {
    IP=$1
    if [[ $IP =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a octets <<< "$IP"
        for octet in "${octets[@]}"; do
            if [ "$octet" -gt 255 ] || [ "$octet" -lt 0 ]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

update_cron() {
    LOG_PATH=$(sqlite3 "$DB_FILE" "SELECT log_path FROM settings LIMIT 1;")
    if [ -z "$LOG_PATH" ]; then
        LOG_PATH="/tmp"
    fi

    JOBS=$(sqlite3 "$DB_FILE" <<'SQL'
SELECT id, schedule, weekdays FROM backup_jobs;
SQL
)
    crontab -l | grep -v $FULLPATH | crontab -

    while IFS="|" read -r ID SCHEDULE WEEKDAYS; do
        HOUR=$(echo "$SCHEDULE" | cut -d':' -f1)
        MINUTE=$(echo "$SCHEDULE" | cut -d':' -f2)

        if [[ "$WEEKDAYS" == "" ]]; then
            WEEKDAYS="*"
        else
            WEEKDAYS=$(echo "$WEEKDAYS" | sed \
                -e 's/Sun/0/g' \
                -e 's/Mon/1/g' \
                -e 's/Tue/2/g' \
                -e 's/Wed/3/g' \
                -e 's/Thu/4/g' \
                -e 's/Fri/5/g' \
                -e 's/Sat/6/g')
        fi

        (crontab -l; echo "$MINUTE $HOUR * * $WEEKDAYS cd $(pwd) && bash $FULLPATH --auto $ID >> \"$LOG_PATH/$ID.log\"") | crontab -
    done <<< "$JOBS"
}

generate_rsync_exclude_args() {
    local JOB_ID="$1"
    local EXCLUDE_ARGS=()

    while IFS= read -r EXCLUDE_PATH; do
        [[ -z "$EXCLUDE_PATH" ]] && continue
        EXCLUDE_ARGS+=( "--exclude=$EXCLUDE_PATH" )
    done < <(sqlite3 "$DB_FILE" "SELECT exclude_path FROM global_excludes;")

    while IFS= read -r EXCLUDE_PATH; do
        [[ -z "$EXCLUDE_PATH" ]] && continue
        EXCLUDE_ARGS+=( "--exclude=$EXCLUDE_PATH" )
    done < <(sqlite3 "$DB_FILE" "SELECT exclude_path FROM job_excludes WHERE job_id = $JOB_ID;")

    echo "${EXCLUDE_ARGS[@]}"
}

run_backup() {
    JOB_ID="$1"
    
    if [ -z "$JOB_ID" ]; then
        echo "Error: No JOB_ID provided. Usage: $0 --auto <JOB_ID>" >&2
        exit 1
    fi
    
    JOB=$(sqlite3 "$DB_FILE" "SELECT id, client_id, disk, max_backups FROM backup_jobs WHERE id = $JOB_ID;")
    IFS="|" read -r ID CLIENT_ID DISK MAX_BACKUPS <<< "$JOB"

    CLIENT=$(sqlite3 "$DB_FILE" "SELECT name, ip, username, password, ssh_key FROM clients WHERE id = $CLIENT_ID;")
    IFS="|" read -r NAME IP USERNAME PASSWORD SSH_KEY <<< "$CLIENT"

    if [[ "$PASSWORD" == ENC:* ]]; then
        ENC_ONLY="${PASSWORD#ENC:}"
        if [ -z "$RBACKUP_MASTER_KEY" ]; then
            echo "Encrypted password found for client $NAME but RBACKUP_MASTER_KEY is not set. Aborting."
            exit 1
        fi
        DECRYPTED=$(decrypt_password "$ENC_ONLY")
        if [ -z "$DECRYPTED" ]; then
            echo "Failed to decrypt password for client $NAME. Check RBACKUP_MASTER_KEY." >&2
            exit 1
        fi
        PASSWORD="$DECRYPTED"
    else
        if [ -n "$PASSWORD" ] && [ -n "$RBACKUP_MASTER_KEY" ]; then
            ENC_PASS=$(encrypt_password "$PASSWORD")
            if [ -n "$ENC_PASS" ]; then
                sqlite3 "$DB_FILE" "UPDATE clients SET password = 'ENC:$ENC_PASS' WHERE id = $CLIENT_ID;"
            fi
        fi
    fi

    SETTINGS=$(sqlite3 "$DB_FILE" "SELECT backup_path, notify_url, log_path FROM settings LIMIT 1;")
    IFS="|" read -r BACKUP_PATH NOTIFY_URL LOG_PATH <<< "$SETTINGS"

    if [ -z "$LOG_PATH" ]; then
        LOG_PATH="/tmp"
        sqlite3 "$DB_FILE" "UPDATE settings SET log_path = '$LOG_PATH';"
    fi

    LOGFILE="$LOG_PATH"/"$JOB_ID".log
    current_date=$(date +%Y%m%d_%H%M%S)
    
    if [ -f "$LOGFILE" ]; then
        rm "$LOGFILE"
    fi
    
    exec 1>>"$LOGFILE"
    exec 2>>"$LOGFILE"
    
    echo "Starting Backup for $NAME at $current_date..."

    BACKUP_DIR="$BACKUP_PATH/$NAME"
    mkdir -p $BACKUP_DIR
    if [ -f "$BACKUP_DIR/$NAME-latest.img" ]; then
        echo -e "${GREEN}[STEP 0]${NC} Creating snapshot of latest backup..."
        cp "$BACKUP_DIR/$NAME-latest.img" $BACKUP_DIR/$NAME-$current_date.img
        echo -e "${GREEN}   ✔ Done${NC}"
    fi
    EXCLUDE_ARGS=( $(generate_rsync_exclude_args "$JOB_ID") )
    if [ "$SSH_KEY" -eq 1 ]; then
        /bin/bash "$SCRIPT_DIR/job.sh" \
          "$USERNAME@$IP" /dev/"$DISK" \
          "$BACKUP_DIR/$NAME-latest.img" "$BACKUP_DIR" \
          "" "${EXCLUDE_ARGS[@]}"
    else
        /bin/bash "$SCRIPT_DIR/job.sh" \
          "$USERNAME@$IP" /dev/"$DISK" \
          "$BACKUP_DIR/$NAME-latest.img" "$BACKUP_DIR" \
          "$PASSWORD" "${EXCLUDE_ARGS[@]}"
    fi

    cleanup_old_backups "$BACKUP_DIR" "$MAX_BACKUPS"

    if [ -s "$LOGFILE" ]; then
        MESSAGE=$(<"$LOGFILE")
        JSON_PAYLOAD=$(jq -n --arg message "$MESSAGE" '{_message: $message}')
        curl -s -o /dev/null -X POST -H 'Content-Type: application/json' -d "$JSON_PAYLOAD" "$NOTIFY_URL" 2>/dev/null
    fi

    echo "Backup Done."

    exit 0
}

cleanup_old_backups() {
    BACKUP_DIR="$1"
    MAX_BACKUPS="$2"

    TOTAL_BACKUPS=$(find "$BACKUP_DIR" -maxdepth 1 -type f | wc -l)

    if [[ "$TOTAL_BACKUPS" -gt "$MAX_BACKUPS" ]]; then
        DELETE_COUNT=$((TOTAL_BACKUPS - MAX_BACKUPS))

        echo "There are $TOTAL_BACKUPS backups, alloewd are $MAX_BACKUPS."
        echo "Deleting the $DELETE_COUNT oldest backups in $BACKUP_DIR ..."

        find "$BACKUP_DIR" -maxdepth 1 -type f -printf '%T@ %p\n' \
            | sort -n \
            | head -n "$DELETE_COUNT" \
            | cut -d' ' -f2- \
            | while read -r file; do
                echo "Deleting: $file"
                rm -f "$file"
              done
    else
        echo "Nothing to delete – there are only $TOTAL_BACKUPS/$MAX_BACKUPS backups."
    fi
}

check_and_install_tools() {
    local -A packages=(
        ["jq"]="jq"
        ["pigz"]="pigz"
        ["sqlite3"]="sqlite3"
        ["whiptail"]="whiptail"
        ["tar"]="tar"
        ["ssh"]="openssh-client"
        ["rsync"]="rsync"
        ["curl"]="curl"
        ["sshpass"]="sshpass"
        ["blkid"]="util-linux"
        ["losetup"]="util-linux"
        ["partprobe"]="parted"
        ["mkfs.vfat"]="dosfstools"
        ["mkfs.ext4"]="e2fsprogs"
        ["mkfs.ext3"]="e2fsprogs"
        ["mkfs.ext2"]="e2fsprogs"
        ["mkswap"]="util-linux"
        ["blockdev"]="util-linux"
        ["sfdisk"]="util-linux"
        ["lsblk"]="util-linux"
        ["fallocate"]="util-linux"
        ["dd"]="coreutils"
        ["mount"]="util-linux"
    )

    local missing_tools=()
    local missing_packages=()

    echo -e "${GREEN}[CHECK]${NC} Checking required tools..."

    for tool in "${!packages[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
            if [[ ! " ${missing_packages[@]} " =~ " ${packages[$tool]} " ]]; then
                missing_packages+=("${packages[$tool]}")
            fi
        fi
    done

    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${ORANGE}Warning:${NC} The following tools are missing: ${missing_tools[*]}"
        echo -e "${ORANGE}Installing:${NC} ${missing_packages[*]}"

        if command -v apt-get &> /dev/null; then
            echo "Using apt-get..."
            sudo apt-get update
            sudo apt-get install -y "${missing_packages[@]}"
        elif command -v yum &> /dev/null; then
            echo "Using yum..."
            sudo yum install -y "${missing_packages[@]}"
        elif command -v pacman &> /dev/null; then
            echo "Using pacman..."
            sudo pacman -S --noconfirm "${missing_packages[@]}"
        elif command -v apk &> /dev/null; then
            echo "Using apk..."
            sudo apk add "${missing_packages[@]}"
        else
            echo -e "${RED}Error:${NC} Could not detect package manager. Please install the following packages manually:"
            echo "${missing_packages[@]}"
            exit 1
        fi

        local still_missing=()
        for tool in "${missing_tools[@]}"; do
            if ! command -v "$tool" &> /dev/null; then
                still_missing+=("$tool")
            fi
        done

        if [ ${#still_missing[@]} -gt 0 ]; then
            echo -e "${RED}Error:${NC} Installation failed. The following tools are still missing: ${still_missing[*]}"
            exit 1
        else
            echo -e "${GREEN}✔${NC} All required tools are now installed."
        fi
    else
        echo -e "${GREEN}✔${NC} All required tools are installed."
    fi
}

# Check and install required tools
check_and_install_tools

# Initialize the database
initialize_db

# Load master key after database initialization
if ! load_master_key_from_db; then
    echo "Error: Failed to load master key from database. Check system UUID consistency."
    exit 1
fi

# Check if script is called with `--auto`
if [[ "$1" == "--auto" ]]; then
    run_backup $2
fi

# Show main menu
main_menu