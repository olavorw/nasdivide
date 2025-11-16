#!/bin/bash
#
# NAS Manual Backup Script
# Triggers immediate backup with options for snapshot and verification
#
# Usage: sudo ./nas-backup.sh [--snapshot] [--verify] [--dry-run]
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
NAS_MOUNT="/srv/nas"
RCLONE_REMOTE="proton-nas:NAS-Backup"
SOURCE_DIR="/srv/nas/data"
LOG_FILE="/var/log/nas-backup-manual.log"

# Options
CREATE_SNAPSHOT=false
VERIFY=false
DRY_RUN=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --snapshot)
            CREATE_SNAPSHOT=true
            shift
            ;;
        --verify)
            VERIFY=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            echo "Usage: $0 [--snapshot] [--verify] [--dry-run]"
            echo ""
            echo "Options:"
            echo "  --snapshot    Create a Btrfs snapshot before backup"
            echo "  --verify      Verify backup integrity after completion"
            echo "  --dry-run     Simulate backup without uploading"
            exit 0
            ;;
    esac
done

# Helper functions
log_info() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1"
    echo -e "${BLUE}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

log_success() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS] $1"
    echo -e "${GREEN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

log_warn() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $1"
    echo -e "${YELLOW}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

log_error() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $1"
    echo -e "${RED}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_mount() {
    if ! mountpoint -q "$NAS_MOUNT"; then
        log_error "NAS not mounted at $NAS_MOUNT"
        exit 1
    fi
}

check_rclone_config() {
    if ! rclone listremotes | grep -q "proton-nas:"; then
        log_error "Proton Drive remote 'proton-nas' not configured"
        log_info "Run: rclone config"
        exit 1
    fi
}

create_snapshot() {
    if [[ "$CREATE_SNAPSHOT" == false ]]; then
        return
    fi

    log_info "Creating pre-backup snapshot..."

    local timestamp=$(date +%Y%m%d-%H%M%S)
    local snapshot_path="$NAS_MOUNT/.snapshots/data-backup-$timestamp"

    btrfs subvolume snapshot -r "$NAS_MOUNT/data" "$snapshot_path" || {
        log_error "Snapshot creation failed"
        exit 1
    }

    log_success "Snapshot created: data-backup-$timestamp"
}

get_transfer_stats() {
    local stats_file="/tmp/rclone-stats.json"
    if [[ -f "$stats_file" ]]; then
        local transferred=$(jq -r '.bytes' "$stats_file" 2>/dev/null || echo "0")
        local files=$(jq -r '.transfers' "$stats_file" 2>/dev/null || echo "0")
        echo "$files files, $(numfmt --to=iec-i --suffix=B $transferred 2>/dev/null || echo $transferred)"
    else
        echo "N/A"
    fi
}

perform_backup() {
    log_info "Starting backup to Proton Drive..."

    if [[ "$DRY_RUN" == true ]]; then
        log_warn "DRY RUN MODE - No data will be uploaded"
    fi

    local start_time=$(date +%s)
    local rclone_opts=(
        --progress
        --transfers 4
        --checkers 8
        --checksum
        --exclude '.snapshots/**'
        --exclude '*.tmp'
        --exclude '*.temp'
        --exclude '.Trash-*/**'
        --log-level INFO
        --stats 10s
        --stats-one-line
    )

    if [[ "$DRY_RUN" == true ]]; then
        rclone_opts+=(--dry-run)
    fi

    # Perform sync
    rclone sync \
        "${rclone_opts[@]}" \
        "$SOURCE_DIR" \
        "$RCLONE_REMOTE" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Backup failed"
            return 1
        }

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Backup completed in ${duration}s"
}

verify_backup() {
    if [[ "$VERIFY" == false ]] || [[ "$DRY_RUN" == true ]]; then
        return
    fi

    log_info "Verifying backup integrity..."

    rclone check \
        --one-way \
        "$SOURCE_DIR" \
        "$RCLONE_REMOTE" 2>&1 | tee -a "$LOG_FILE" || {
            log_error "Verification failed - backup may be incomplete"
            return 1
        }

    log_success "Verification completed - backup is consistent"
}

show_backup_info() {
    log_info "Backup Summary:"
    echo "  Source: $SOURCE_DIR"
    echo "  Destination: $RCLONE_REMOTE"
    echo "  Log: $LOG_FILE"

    if [[ "$DRY_RUN" == false ]]; then
        # Get remote info
        log_info "Checking remote storage..."
        rclone about "$RCLONE_REMOTE" 2>/dev/null || log_warn "Could not retrieve remote storage info"
    fi
}

cleanup_old_snapshots() {
    if [[ "$CREATE_SNAPSHOT" == false ]]; then
        return
    fi

    log_info "Cleaning up old backup snapshots..."

    local snapshot_dir="$NAS_MOUNT/.snapshots"
    local retention=5  # Keep last 5 manual backup snapshots

    if [[ ! -d "$snapshot_dir" ]]; then
        return
    fi

    local backup_snapshots=($(ls -1t "$snapshot_dir" | grep "^data-backup-" || true))
    local count=${#backup_snapshots[@]}

    if [[ $count -gt $retention ]]; then
        log_info "Found $count backup snapshots, removing oldest..."
        for ((i=retention; i<count; i++)); do
            local snap="${backup_snapshots[$i]}"
            log_info "Removing old snapshot: $snap"
            btrfs subvolume delete "$snapshot_dir/$snap" || log_warn "Failed to delete $snap"
        done
        log_success "Cleanup completed"
    else
        log_info "Snapshot count ($count) within retention policy ($retention)"
    fi
}

main() {
    log_info "==================================="
    log_info "NAS Manual Backup"
    log_info "==================================="
    echo ""

    check_root
    check_mount
    check_rclone_config

    if [[ "$CREATE_SNAPSHOT" == true ]]; then
        log_info "Snapshot: ENABLED"
    fi
    if [[ "$VERIFY" == true ]]; then
        log_info "Verification: ENABLED"
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log_warn "Mode: DRY RUN"
    fi
    echo ""

    create_snapshot
    perform_backup
    verify_backup
    cleanup_old_snapshots
    show_backup_info

    echo ""
    log_success "Backup process complete"
}

main "$@"
