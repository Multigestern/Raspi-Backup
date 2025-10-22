#!/bin/bash
#
# job.sh
#
# This script can be used in two ways:
#
# 1. Full backup: If no backup image exists yet, a complete image of the remote
#    device (e.g., /dev/mmcblk0) will be created, including the partition table,
#    formatting, and data copied via rsync (excluding virtual file systems).
#
# 2. Incremental backup: If the OUTPUT_IMAGE already exists, the data in each
#    partition (that has a mount point) will be incrementally updated from the
#    remote system using rsync.
#
# Call:
#   sudo ./job.sh REMOTE_HOST REMOTE_DEVICE OUTPUT_IMAGE WORK_DIRECTORY [EXCLUDES...]
#
# Example:
#   sudo ./job.sh root@10.0.1.41 /dev/mmcblk0 example.img /tmp \
#       --exclude=/proc/* --exclude=/sys/* --exclude=/dev/* --exclude=/run/*

set -e

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root."
  exit 1
fi

# Usage check: at least 4 parameters
if [ "$#" -lt 4 ]; then
  echo "Usage: $0 REMOTE_HOST REMOTE_DEVICE OUTPUT_IMAGE WORK_DIRECTORY [EXCLUDES...]"
  exit 1
fi

REMOTE_HOST="$1"      # e.g. root@10.0.1.41
REMOTE_DEV="$2"       # e.g. /dev/mmcblk0
OUTPUT_IMAGE="$3"     # e.g. example.img
WORK_DIRECTORY="$4"   # e.g. /tmp
shift 4
PASSWORD="$1"
shift 1
EXCLUDES=("$@")       # any additional rsync exclude options

if [ -n "$PASSWORD" ]; then
  SSH_CMD="sshpass -p '$PASSWORD' ssh -o StrictHostKeyChecking=no"
else
  SSH_CMD="ssh -o StrictHostKeyChecking=no"
fi
export RSYNC_RSH="$SSH_CMD"

# Color definitions
GREEN='\033[0;32m'
RED='\033[0;31m'
ORANGE='\033[0;33m'
NC='\033[0m'

log_step() {
    local step="$1"
    local message="$2"
    echo -e "${GREEN}[STEP $step]${NC} $message"
}

log_done() {
    echo -e "${GREEN}   ✔${NC} Done"
}

log_error() {
    local message="$1"
    echo -e "${RED}Error:${NC} $message"
}

log_warning() {
    local message="$1"
    echo -e "${ORANGE}Warning:${NC} $message"
}

rsync_remote() {
  local src="$1" dst="$2"
  local rsync_opts=( -aAX --inplace --delete )
  if [ "${#EXCLUDES[@]}" -gt 0 ]; then
    rsync_opts+=( "${EXCLUDES[@]}" )
  else
    rsync_opts+=( --exclude="/proc/*" --exclude="/sys/*" --exclude="/dev/*" --exclude="/run/*" )
  fi
  
  # Add these options for better handling of errors
  rsync_opts+=( 
    --ignore-errors 
    --partial
    --no-whole-file
  )
  
  rsync "${rsync_opts[@]}" "$src" "$dst" < /dev/null
  local rsync_exit=$?
  
  case $rsync_exit in
    0)  return 0 ;;
    23|24) 
      log_warning "Warning: Partial transfer (some files not copied, possibly due to space constraints)"
      return 0 ;;
    11) 
      log_warning "Warning: Some files were not copied due to space constraints"
      return 0 ;;
    *)  
      log_error "Error: rsync failed with exit code $rsync_exit"
      return 1 ;;
  esac
}

get_fs_info() {
  local part="$1"
  local ret
  ret=$($SSH_CMD "$REMOTE_HOST" "sudo blkid -s LABEL -s UUID -o export /dev/$part" 2>/dev/null || echo "")
  local label uuid
  label=$(echo "$ret" | grep '^LABEL=' | cut -d '=' -f2)
  uuid=$(echo "$ret" | grep '^UUID=' | cut -d '=' -f2)
  echo "$label" "$uuid"
}

check_tools() {
    commands=("blockdev" "sfdisk" "lsblk" "blkid" "losetup" "partprobe" "fallocate" "dd" "mkfs.vfat" "mkfs.ext4" "mkfs.ext3" "mkfs.ext2" "mkswap" "mount" "rsync")

    for tool in "${commands[@]}"; do
        if ! command -v "$commands" &> /dev/null; then
            log_error "Error: $commands is not installed. Please install it using your package manager."
            exit 1
        fi
    done
}

mount_partition() {
  local part="$1"
  local mountpoint="$2"
  local fstype="$3"
  
  case "$fstype" in
    vfat)
      mount -t vfat -o codepage=437,iocharset=ascii,shortname=mixed,utf8 "$part" "$mountpoint"
      ;;
    ext4|ext3|ext2)
      mount -t "$fstype" "$part" "$mountpoint"
      ;;
    *)
      mount "$part" "$mountpoint"
      ;;
  esac
}

log_step 1 "Checking required tools"
check_tools
log_done

if [ ! -f "$OUTPUT_IMAGE" ]; then
  ##########################
  # Performing full backup #
  ##########################
  log_step 2 "Creating full backup image for remote device $REMOTE_DEV on $REMOTE_HOST ..."
  echo "Target image: $OUTPUT_IMAGE"

  IMAGE_SIZE=$(ssh "$REMOTE_HOST" "sudo blockdev --getsize64 $REMOTE_DEV")
  echo "Size of the remote device: $IMAGE_SIZE Bytes"

  log_step 3 "Create emptry image..."
  if command -v fallocate &>/dev/null; then
    fallocate -l "$IMAGE_SIZE" "$OUTPUT_IMAGE"
  else
    dd if=/dev/zero of="$OUTPUT_IMAGE" bs=1 count=0 seek="$IMAGE_SIZE"
  fi
  log_done

  log_step 4 "Exporting partition table from remote device..."
  TMP_PART_TABLE=$(mktemp $WORK_DIRECTORY/partition_table.XXXXXX)
  ssh "$REMOTE_HOST" "sudo sfdisk -d $REMOTE_DEV" > "$TMP_PART_TABLE"
  log_done

  log_step 5 "Creating partitions and formatting them..."
  LOOPDEV=$(losetup -f --show "$OUTPUT_IMAGE")
  echo "Image mounted as loop device: $LOOPDEV"

  sfdisk "$LOOPDEV" < "$TMP_PART_TABLE"

  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$LOOPDEV" 2>/dev/null || true
  else
    if command -v partx >/dev/null 2>&1; then
      partx -a "$LOOPDEV" 2>/dev/null || true
    else
      log_warning "Warning: Neither partprobe nor partx found. Please reload the partition table manually."
    fi
  fi
  sleep 2

  losetup -d "$LOOPDEV"
  LOOPDEV=$(losetup -f --show -P "$OUTPUT_IMAGE")
  echo "New loop device: $LOOPDEV"

  MAPFILE=$(mktemp $WORK_DIRECTORY/partition_map.XXXXXX)
  ssh "$REMOTE_HOST" "lsblk -ln -o NAME,MOUNTPOINT,FSTYPE $REMOTE_DEV" | while read -r NAME MOUNT FSTYPE; do
    if [ -n "$FSTYPE" ]; then
      echo "$NAME $MOUNT $FSTYPE" >> "$MAPFILE"
    fi
  done

  echo "Detected partitions on the remote device (Name, Mountpoint, Fstype):"
  cat "$MAPFILE"

  mapfile -t PARTITIONS < "$MAPFILE"

  for LINE in "${PARTITIONS[@]}"; do
    read -r PART_NAME MOUNTPOINT FSTYPE <<< "$LINE"

    if [[ "$PART_NAME" =~ [^0-9]*([0-9]+)$ ]]; then
      PART_NUM="${BASH_REMATCH[1]}"
    else
      echo "Cannot determine partition number from $PART_NAME, skipping."
      continue
    fi

    LOOP_PART="${LOOPDEV}p${PART_NUM}"
    if [ ! -b "$LOOP_PART" ]; then
      LOOP_PART="${LOOPDEV}${PART_NUM}"
    fi
    if [ ! -b "$LOOP_PART" ]; then
      echo "Loop partition for partition number $PART_NUM not found, skipping."
      continue
    fi

    echo "Processing remote partition /dev/$PART_NAME: fstype=$FSTYPE, mountpoint='$MOUNTPOINT'"

    read ORG_LABEL ORG_UUID < <(get_fs_info "$PART_NAME")
    echo "  Original Label: ${ORG_LABEL:-(keins)}, UUID: ${ORG_UUID:-(keins)}"

    if [ -n "$MOUNTPOINT" ]; then
      SRC_SIZE=$(ssh "$REMOTE_HOST" "df -B1 '$MOUNTPOINT'" | awk 'NR==2 {print $3}')
      DST_SIZE=$(blockdev --getsize64 "$LOOP_PART")
      if [ "$SRC_SIZE" -gt "$DST_SIZE" ]; then
        log_warning "Warning: Source partition ($((SRC_SIZE/1024/1024))MB) is larger than destination ($((DST_SIZE/1024/1024))MB)"
        echo "         Some files may not be copied due to space constraints"
      fi
    fi

    case "$FSTYPE" in
      vfat)
        echo "  Formatting as FAT32..."
        if [ -n "$ORG_LABEL" ]; then
          mkfs.vfat -F 32 -n "$ORG_LABEL" "$LOOP_PART"
        else
          mkfs.vfat -F 32 "$LOOP_PART"
        fi
        ;;
      ext4)
        echo "  Formatting as ext4..."
        if [ -n "$ORG_LABEL" ] && [ -n "$ORG_UUID" ]; then
          mkfs.ext4 -F -L "$ORG_LABEL" -U "$ORG_UUID" "$LOOP_PART"
        elif [ -n "$ORG_LABEL" ]; then
          mkfs.ext4 -F -L "$ORG_LABEL" "$LOOP_PART"
        elif [ -n "$ORG_UUID" ]; then
          mkfs.ext4 -F -U "$ORG_UUID" "$LOOP_PART"
        else
          mkfs.ext4 -F "$LOOP_PART"
        fi
        ;;
      ext3)
        echo "  Formatting as ext3..."
        if [ -n "$ORG_LABEL" ] && [ -n "$ORG_UUID" ]; then
          mkfs.ext3 -F -L "$ORG_LABEL" -U "$ORG_UUID" "$LOOP_PART"
        elif [ -n "$ORG_LABEL" ]; then
          mkfs.ext3 -F -L "$ORG_LABEL" "$LOOP_PART"
        elif [ -n "$ORG_UUID" ]; then
          mkfs.ext3 -F -U "$ORG_UUID" "$LOOP_PART"
        else
          mkfs.ext3 -F "$LOOP_PART"
        fi
        ;;
      ext2)
        echo "  Formatting as ext2..."
        if [ -n "$ORG_LABEL" ] && [ -n "$ORG_UUID" ]; then
          mkfs.ext2 -F -L "$ORG_LABEL" -U "$ORG_UUID" "$LOOP_PART"
        elif [ -n "$ORG_LABEL" ]; then
          mkfs.ext2 -F -L "$ORG_LABEL" "$LOOP_PART"
        elif [ -n "$ORG_UUID" ]; then
          mkfs.ext2 -F -U "$ORG_UUID" "$LOOP_PART"
        else
          mkfs.ext2 -F "$LOOP_PART"
        fi
        ;;
      swap)
        echo "  Formatting as Swap..."
        if [ -n "$ORG_LABEL" ] && [ -n "$ORG_UUID" ]; then
          mkswap -L "$ORG_LABEL" -U "$ORG_UUID" "$LOOP_PART"
        elif [ -n "$ORG_LABEL" ]; then
          mkswap -L "$ORG_LABEL" "$LOOP_PART"
        elif [ -n "$ORG_UUID" ]; then
          mkswap -U "$ORG_UUID" "$LOOP_PART"
        else
          mkswap "$LOOP_PART"
        fi
        continue
        ;;
      *)
        echo "  Warning: Filesystem type $FSTYPE is not automatically handled. Skipping partition $LOOP_PART."
        continue
        ;;
    esac

    if [ -n "$MOUNTPOINT" ]; then
      echo "  Copying data from remote mountpoint $MOUNTPOINT..."
      TMP_MNT=$(mktemp -d $WORK_DIRECTORY/newpart.XXXXXX)
      if ! mount_partition "$LOOP_PART" "$TMP_MNT" "$FSTYPE"; then
        log_warning "Warning: Failed to mount $LOOP_PART, skipping"
        rmdir "$TMP_MNT"
        continue
      fi
      if ! rsync_remote "$REMOTE_HOST:$MOUNTPOINT"/ "$TMP_MNT"/; then
        log_warning "Warning: Rsync reported warnings/errors but continuing with backup"
      fi
      sync
      umount "$TMP_MNT" || log_warning "Warning: Failed to unmount $TMP_MNT"
      rmdir "$TMP_MNT" || log_warning "Warning: Failed to remove $TMP_MNT"
    else
      echo "  No mountpoint - skipping data copy."
    fi

  done
  log_done

  log_step 6 "Cleaning up..."
  rm -f "$TMP_PART_TABLE" "$MAPFILE"
  losetup -d "$LOOPDEV"
  log_done

  echo "Done! The full backup has been created: $OUTPUT_IMAGE"

else
  #################################
  # Performing incremental backup #
  #################################
  log_step 2 "Incremental backup: Updating existing image $OUTPUT_IMAGE ..."

  log_step 3 "Mounting image and preparing partition map..."
  LOOPDEV=$(losetup -f --show -P "$OUTPUT_IMAGE")
  

  MAPFILE=$(mktemp $WORK_DIRECTORY/partition_map.XXXXXX)
  ssh "$REMOTE_HOST" "lsblk -ln -o NAME,MOUNTPOINT,FSTYPE $REMOTE_DEV" | while read -r NAME MOUNT FSTYPE; do
    if [ -n "$FSTYPE" ]; then
      echo "$NAME $MOUNT $FSTYPE" >> "$MAPFILE"
    fi
  done

  echo "Detected partitions on the remote device (Name, Mountpoint, Fstype):"
  cat "$MAPFILE"

  mapfile -t PARTITIONS < "$MAPFILE"
  log_done

  log_step 4 "Updating partitions..."
  for LINE in "${PARTITIONS[@]}"; do
    read -r PART_NAME MOUNTPOINT FSTYPE <<< "$LINE"

    if [[ "$PART_NAME" =~ [^0-9]*([0-9]+)$ ]]; then
      PART_NUM="${BASH_REMATCH[1]}"
    else
      echo "Cannot determine partition number from $PART_NAME, skipping."
      continue
    fi

    LOOP_PART="${LOOPDEV}p${PART_NUM}"
    if [ ! -b "$LOOP_PART" ]; then
      LOOP_PART="${LOOPDEV}${PART_NUM}"
    fi
    if [ ! -b "$LOOP_PART" ]; then
      echo "Loop partition for partition number $PART_NUM not found, skipping."
      continue
    fi

    echo "Updating remote partition /dev/$PART_NAME: fstype=$FSTYPE, mountpoint='$MOUNTPOINT'"

    if [ -n "$MOUNTPOINT" ]; then
      SRC_SIZE=$(ssh "$REMOTE_HOST" "df -B1 '$MOUNTPOINT'" | awk 'NR==2 {print $3}')
      DST_SIZE=$(blockdev --getsize64 "$LOOP_PART")
      if [ "$SRC_SIZE" -gt "$DST_SIZE" ]; then
        log_warning "Warning: Source partition ($((SRC_SIZE/1024/1024))MB) is larger than destination ($((DST_SIZE/1024/1024))MB)"
        echo "         Some files may not be copied due to space constraints"
      fi
    fi

    if [ "$FSTYPE" = "swap" ]; then
      echo "  Swap partition will not be updated."
      continue
    fi

    if [ -n "$MOUNTPOINT" ]; then
      echo "  Copying data from remote mountpoint $MOUNTPOINT..."
      TMP_MNT=$(mktemp -d $WORK_DIRECTORY/newpart.XXXXXX)
      if ! mount_partition "$LOOP_PART" "$TMP_MNT" "$FSTYPE"; then
        log_warning "Warning: Failed to mount $LOOP_PART, skipping"
        rmdir "$TMP_MNT"
        continue
      fi
      if ! rsync_remote "$REMOTE_HOST:$MOUNTPOINT"/ "$TMP_MNT"/; then
        log_warning "Warning: Rsync reported warnings/errors but continuing with backup"
      fi
      sync
      umount "$TMP_MNT" || log_warning "Warning: Failed to unmount $TMP_MNT"
      rmdir "$TMP_MNT" || log_warning "Warning: Failed to remove $TMP_MNT"
    else
      echo "  No mountpoint – skipping update."
    fi

  done
  log_done

  log_step 5 "Cleaning up..."
  rm -f "$MAPFILE"
  losetup -d "$LOOPDEV"
  log_done

  echo "Done! The incremental backup has been updated: $OUTPUT_IMAGE"
fi