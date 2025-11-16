#!/bin/bash
#
# NAS Configuration File (Example)
# Copy this to config.sh and customize for your setup
#
# Usage: cp config.example.sh config.sh
#        Edit config.sh with your values
#

# ====================
# Drive Configuration
# ====================

# The drive to use for NAS storage (will be wiped during setup!)
# Find available drives with: lsblk -d -o NAME,SIZE,TYPE | grep disk
NAS_DRIVE="/dev/sdb"

# ====================
# Mount Configuration
# ====================

# Where to mount the NAS filesystem
NAS_MOUNT="/srv/nas"

# ====================
# User Configuration
# ====================

# System user for NAS operations (will be created)
NAS_USER="nas"
NAS_GROUP="nas"
NAS_UID=900
NAS_GID=900

# ====================
# LUKS Configuration
# ====================

# Name for the LUKS encrypted device (will appear as /dev/mapper/$LUKS_NAME)
LUKS_NAME="nas-data"

# Encryption settings (advanced users only)
LUKS_CIPHER="aes-xts-plain64"
LUKS_KEY_SIZE="512"
LUKS_HASH="sha512"
LUKS_PBKDF="argon2id"

# ====================
# Btrfs Configuration
# ====================

# Filesystem label
BTRFS_LABEL="NAS-DATA"

# Compression algorithm and level
# Options: zstd:1 (fast) to zstd:15 (max compression)
# Default: zstd:3 (balanced)
BTRFS_COMPRESSION="zstd:3"

# Enable auto-defrag (recommended for HDDs, optional for SSDs)
BTRFS_AUTODEFRAG="yes"

# ====================
# Snapshot Configuration
# ====================

# How often to create snapshots
SNAPSHOT_INTERVAL="hourly"  # hourly, daily, weekly

# Number of snapshots to retain
RETENTION_HOURLY=24   # Keep 24 hourly snapshots (1 day)
RETENTION_DAILY=7     # Keep 7 daily snapshots (1 week)
RETENTION_WEEKLY=4    # Keep 4 weekly snapshots (1 month)

# ====================
# Proton Drive Configuration
# ====================

# Remote name (must match rclone config)
RCLONE_REMOTE="proton-nas"

# Remote path on Proton Drive
RCLONE_PATH="NAS-Backup"

# Full remote string (combination of above)
RCLONE_FULL="${RCLONE_REMOTE}:${RCLONE_PATH}"

# How often to sync to Proton Drive
PROTON_SYNC_INTERVAL="daily"  # daily, weekly, monthly

# Number of parallel transfers
RCLONE_TRANSFERS=4

# Number of parallel checkers
RCLONE_CHECKERS=8

# Additional rclone options (space-separated)
RCLONE_EXTRA_OPTS="--exclude '*.tmp' --exclude '*.temp'"

# ====================
# Samba Configuration
# ====================

# Workgroup name
SAMBA_WORKGROUP="WORKGROUP"

# Server description
SAMBA_SERVER_STRING="Arch NAS"

# Minimum SMB protocol version (SMB3 recommended for security)
SAMBA_MIN_PROTOCOL="SMB3"

# Require encryption
SAMBA_ENCRYPT="required"

# Bind only to Tailscale interface (recommended)
# Set to "yes" to restrict access to Tailscale only
# Set to "no" to allow access from all interfaces
SAMBA_TAILSCALE_ONLY="yes"

# ====================
# Tailscale Configuration
# ====================

# Tailscale is configured separately via: sudo tailscale up
# No configuration needed here

# ====================
# Security Configuration
# ====================

# Enable TPM2 auto-unlock (if available)
ENABLE_TPM2="yes"

# PCRs to use for TPM2 (default: 0+7 for secure boot)
TPM2_PCRS="0+7"

# File permissions
DIR_PERMS_DATA=770    # Permissions for /srv/nas/data
DIR_PERMS_SHARES=770  # Permissions for /srv/nas/shares
DIR_PERMS_BACKUP=700  # Permissions for /srv/nas/backup

# ====================
# Logging Configuration
# ====================

# Log directory
LOG_DIR="/var/log"

# Proton sync log file
PROTON_LOG="${LOG_DIR}/nas-proton-sync.log"

# Maximum log size (in bytes)
MAX_LOG_SIZE=10485760  # 10MB

# Log level (INFO, WARN, ERROR, DEBUG)
LOG_LEVEL="INFO"

# ====================
# Performance Configuration
# ====================

# Optimize for SSD or HDD
# Options: "ssd" or "hdd"
STORAGE_TYPE="ssd"

# Additional mount options based on storage type
# SSD: ssd,discard=async
# HDD: autodefrag
MOUNT_OPTS_SSD="ssd,discard=async"
MOUNT_OPTS_HDD="autodefrag"

# ====================
# Notification Configuration
# ====================

# Enable email notifications (requires configured mail system)
ENABLE_NOTIFICATIONS="no"

# Email address for notifications
NOTIFY_EMAIL="admin@example.com"

# ====================
# Backup Configuration
# ====================

# Create snapshot before Proton Drive sync
SNAPSHOT_BEFORE_BACKUP="yes"

# Verify backup after sync
VERIFY_AFTER_BACKUP="yes"

# Retry failed backups
BACKUP_RETRY_COUNT=3
BACKUP_RETRY_DELAY=300  # seconds

# ====================
# Advanced Configuration
# ====================

# Enable automatic scrub (data integrity check)
ENABLE_AUTO_SCRUB="yes"
SCRUB_INTERVAL="monthly"

# Enable automatic balance
ENABLE_AUTO_BALANCE="no"
BALANCE_INTERVAL="monthly"
BALANCE_USAGE_THRESHOLD=50  # Percentage

# Systemd service hardening
SYSTEMD_HARDENING="yes"

# ====================
# Feature Flags
# ====================

# Enable experimental features
ENABLE_EXPERIMENTAL="no"

# Enable verbose logging
VERBOSE="no"

# Dry run mode (test without making changes)
DRY_RUN="no"

# ====================
# Package Configuration
# ====================

# Additional packages to install (space-separated)
ADDITIONAL_PACKAGES=""

# Package manager (yay, paru, pacman)
PACKAGE_MANAGER="yay"

# ====================
# End of Configuration
# ====================

# Validation function (do not edit)
validate_config() {
    local errors=0

    # Check if drive exists
    if [[ ! -b "$NAS_DRIVE" ]]; then
        echo "ERROR: Drive $NAS_DRIVE does not exist"
        ((errors++))
    fi

    # Check if mount point is valid
    if [[ "$NAS_MOUNT" == "/" ]] || [[ "$NAS_MOUNT" == "/home" ]]; then
        echo "ERROR: Invalid mount point $NAS_MOUNT"
        ((errors++))
    fi

    # Check compression level
    if [[ ! "$BTRFS_COMPRESSION" =~ ^zstd:[1-9]|1[0-5]$ ]]; then
        echo "WARNING: Invalid compression level, using default zstd:3"
        BTRFS_COMPRESSION="zstd:3"
    fi

    return $errors
}

# Export all variables
export NAS_DRIVE NAS_MOUNT NAS_USER NAS_GROUP NAS_UID NAS_GID
export LUKS_NAME LUKS_CIPHER LUKS_KEY_SIZE LUKS_HASH LUKS_PBKDF
export BTRFS_LABEL BTRFS_COMPRESSION BTRFS_AUTODEFRAG
export SNAPSHOT_INTERVAL RETENTION_HOURLY RETENTION_DAILY RETENTION_WEEKLY
export RCLONE_REMOTE RCLONE_PATH RCLONE_FULL PROTON_SYNC_INTERVAL
export RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_EXTRA_OPTS
export SAMBA_WORKGROUP SAMBA_SERVER_STRING SAMBA_MIN_PROTOCOL SAMBA_ENCRYPT
export SAMBA_TAILSCALE_ONLY ENABLE_TPM2 TPM2_PCRS
export DIR_PERMS_DATA DIR_PERMS_SHARES DIR_PERMS_BACKUP
export LOG_DIR PROTON_LOG MAX_LOG_SIZE LOG_LEVEL
export STORAGE_TYPE MOUNT_OPTS_SSD MOUNT_OPTS_HDD
export ENABLE_NOTIFICATIONS NOTIFY_EMAIL
export SNAPSHOT_BEFORE_BACKUP VERIFY_AFTER_BACKUP
export BACKUP_RETRY_COUNT BACKUP_RETRY_DELAY
export ENABLE_AUTO_SCRUB SCRUB_INTERVAL
export ENABLE_AUTO_BALANCE BALANCE_INTERVAL BALANCE_USAGE_THRESHOLD
export SYSTEMD_HARDENING ENABLE_EXPERIMENTAL VERBOSE DRY_RUN
export ADDITIONAL_PACKAGES PACKAGE_MANAGER
