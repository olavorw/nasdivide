#!/bin/bash
#
# NAS Status Script
# Displays comprehensive status of NAS system
#
# Usage: sudo ./nas-status.sh [--json]
#

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
NAS_MOUNT="/srv/nas"
NAS_USER="nas"
LUKS_NAME="nas-data"
OUTPUT_JSON=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --json)
            OUTPUT_JSON=true
            shift
            ;;
    esac
done

# Helper functions
print_header() {
    if [[ "$OUTPUT_JSON" == false ]]; then
        echo -e "${BOLD}${BLUE}$1${NC}"
        echo "----------------------------------------"
    fi
}

print_status() {
    local label="$1"
    local value="$2"
    local status="${3:-}"

    if [[ "$OUTPUT_JSON" == false ]]; then
        case "$status" in
            ok)
                echo -e "${label}: ${GREEN}${value}${NC}"
                ;;
            warn)
                echo -e "${label}: ${YELLOW}${value}${NC}"
                ;;
            error)
                echo -e "${label}: ${RED}${value}${NC}"
                ;;
            *)
                echo -e "${label}: ${value}"
                ;;
        esac
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root"
        exit 1
    fi
}

get_encryption_status() {
    if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
        echo "Unlocked"
        return 0
    else
        echo "Locked"
        return 1
    fi
}

get_mount_status() {
    if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
        echo "Mounted"
        return 0
    else
        echo "Not Mounted"
        return 1
    fi
}

get_disk_usage() {
    if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
        df -h "$NAS_MOUNT" | awk 'NR==2 {print $3 " / " $2 " (" $5 ")"}'
    else
        echo "N/A"
    fi
}

get_filesystem_info() {
    if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
        btrfs filesystem show "$NAS_MOUNT" 2>/dev/null | grep "Label:" | awk '{print $2}'
    else
        echo "N/A"
    fi
}

check_service_status() {
    local service="$1"
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        echo "Running"
        return 0
    elif systemctl is-enabled --quiet "$service" 2>/dev/null; then
        echo "Enabled (Not Running)"
        return 1
    else
        echo "Inactive"
        return 2
    fi
}

get_last_backup() {
    local log_file="/var/log/nas-proton-sync.log"
    if [[ -f "$log_file" ]]; then
        grep "Sync completed successfully" "$log_file" | tail -1 | sed 's/^\[\(.*\)\].*/\1/' || echo "Never"
    else
        echo "Never"
    fi
}

get_snapshot_count() {
    if [[ -d "$NAS_MOUNT/.snapshots" ]]; then
        find "$NAS_MOUNT/.snapshots" -maxdepth 1 -type d -name "data-*" 2>/dev/null | wc -l
    else
        echo "0"
    fi
}

get_latest_snapshot() {
    if [[ -d "$NAS_MOUNT/.snapshots" ]]; then
        ls -1t "$NAS_MOUNT/.snapshots" | grep "^data-" | head -1 | sed 's/data-//' || echo "None"
    else
        echo "None"
    fi
}

get_tailscale_status() {
    if command -v tailscale &> /dev/null; then
        if tailscale status &>/dev/null; then
            local ip=$(tailscale ip -4 2>/dev/null | head -1)
            if [[ -n "$ip" ]]; then
                echo "Connected ($ip)"
                return 0
            else
                echo "Disconnected"
                return 1
            fi
        else
            echo "Not Running"
            return 2
        fi
    else
        echo "Not Installed"
        return 3
    fi
}

get_samba_shares() {
    if command -v smbstatus &> /dev/null; then
        smbstatus -S 2>/dev/null | grep -c "nas-" || echo "0"
    else
        echo "N/A"
    fi
}

get_active_connections() {
    if command -v smbstatus &> /dev/null; then
        smbstatus -b 2>/dev/null | grep -c "^[0-9]" || echo "0"
    else
        echo "0"
    fi
}

check_btrfs_errors() {
    if mountpoint -q "$NAS_MOUNT" 2>/dev/null; then
        local errors=$(btrfs device stats "$NAS_MOUNT" 2>/dev/null | grep -v "write_io_errs.0" | grep -v "read_io_errs.0" | grep -v "flush_io_errs.0" | grep -v "corruption_errs.0" | grep -v "generation_errs.0" | wc -l)
        if [[ $errors -gt 0 ]]; then
            echo "Errors Detected"
            return 1
        else
            echo "Healthy"
            return 0
        fi
    else
        echo "N/A"
    fi
}

get_rclone_config_status() {
    if rclone listremotes 2>/dev/null | grep -q "proton-nas:"; then
        echo "Configured"
        return 0
    else
        echo "Not Configured"
        return 1
    fi
}

display_status() {
    print_header "NAS System Status"
    echo ""

    # Encryption Status
    local enc_status=$(get_encryption_status)
    if [[ "$enc_status" == "Unlocked" ]]; then
        print_status "Encryption" "$enc_status" "ok"
    else
        print_status "Encryption" "$enc_status" "warn"
    fi

    # Mount Status
    local mount_status=$(get_mount_status)
    if [[ "$mount_status" == "Mounted" ]]; then
        print_status "Mount Point" "$NAS_MOUNT" "ok"
    else
        print_status "Mount Point" "$NAS_MOUNT (Not Mounted)" "error"
    fi

    # Disk Usage
    print_status "Disk Usage" "$(get_disk_usage)"

    # Filesystem
    print_status "Filesystem" "Btrfs"

    # Btrfs Health
    local btrfs_health=$(check_btrfs_errors)
    if [[ "$btrfs_health" == "Healthy" ]]; then
        print_status "Filesystem Health" "$btrfs_health" "ok"
    else
        print_status "Filesystem Health" "$btrfs_health" "error"
    fi

    echo ""
    print_header "Services"
    echo ""

    # Samba
    local smb_status=$(check_service_status smb)
    if [[ "$smb_status" == "Running" ]]; then
        print_status "Samba (SMB)" "$smb_status" "ok"
    else
        print_status "Samba (SMB)" "$smb_status" "warn"
    fi

    # Proton Sync
    local sync_status=$(check_service_status nas-proton-sync.timer)
    if [[ "$sync_status" == "Running" ]]; then
        print_status "Proton Sync Timer" "$sync_status" "ok"
    else
        print_status "Proton Sync Timer" "$sync_status" "warn"
    fi

    # Snapshot Timer
    local snap_status=$(check_service_status nas-snapshot.timer)
    if [[ "$snap_status" == "Running" ]]; then
        print_status "Snapshot Timer" "$snap_status" "ok"
    else
        print_status "Snapshot Timer" "$snap_status" "warn"
    fi

    # Tailscale
    local ts_status=$(get_tailscale_status)
    if [[ "$ts_status" == Connected* ]]; then
        print_status "Tailscale" "$ts_status" "ok"
    else
        print_status "Tailscale" "$ts_status" "warn"
    fi

    echo ""
    print_header "Backups & Snapshots"
    echo ""

    # Rclone Config
    local rclone_status=$(get_rclone_config_status)
    if [[ "$rclone_status" == "Configured" ]]; then
        print_status "Proton Drive Config" "$rclone_status" "ok"
    else
        print_status "Proton Drive Config" "$rclone_status" "error"
    fi

    # Last Backup
    print_status "Last Proton Backup" "$(get_last_backup)"

    # Snapshots
    print_status "Snapshot Count" "$(get_snapshot_count)"
    print_status "Latest Snapshot" "$(get_latest_snapshot)"

    echo ""
    print_header "Network & Sharing"
    echo ""

    # Active Shares
    print_status "Samba Shares" "$(get_samba_shares)"

    # Active Connections
    print_status "Active Connections" "$(get_active_connections)"

    echo ""
    print_header "User & Permissions"
    echo ""

    # NAS User
    if id "$NAS_USER" &>/dev/null; then
        print_status "NAS User" "Exists ($NAS_USER)" "ok"
    else
        print_status "NAS User" "Missing" "error"
    fi

    # Directory Permissions
    if [[ -d "$NAS_MOUNT/data" ]]; then
        local perms=$(stat -c "%a" "$NAS_MOUNT/data" 2>/dev/null || echo "N/A")
        print_status "Data Dir Permissions" "$perms"
    fi

    echo ""
}

display_json() {
    cat << EOF
{
    "encryption": {
        "status": "$(get_encryption_status)",
        "device": "/dev/mapper/$LUKS_NAME"
    },
    "mount": {
        "status": "$(get_mount_status)",
        "path": "$NAS_MOUNT",
        "usage": "$(get_disk_usage)"
    },
    "filesystem": {
        "type": "btrfs",
        "health": "$(check_btrfs_errors)"
    },
    "services": {
        "samba": "$(check_service_status smb)",
        "proton_sync": "$(check_service_status nas-proton-sync.timer)",
        "snapshots": "$(check_service_status nas-snapshot.timer)",
        "tailscale": "$(get_tailscale_status)"
    },
    "backups": {
        "rclone_configured": "$(get_rclone_config_status)",
        "last_backup": "$(get_last_backup)",
        "snapshot_count": $(get_snapshot_count),
        "latest_snapshot": "$(get_latest_snapshot)"
    },
    "network": {
        "samba_shares": $(get_samba_shares),
        "active_connections": $(get_active_connections)
    }
}
EOF
}

show_quick_commands() {
    if [[ "$OUTPUT_JSON" == false ]]; then
        print_header "Quick Commands"
        echo ""
        echo "View Services:"
        echo "  systemctl status smb"
        echo "  systemctl status nas-proton-sync.timer"
        echo "  systemctl status nas-snapshot.timer"
        echo ""
        echo "Manual Operations:"
        echo "  sudo /usr/local/bin/nas-proton-sync.sh  # Run backup now"
        echo "  sudo /usr/local/bin/nas-snapshot.sh     # Create snapshot now"
        echo ""
        echo "View Logs:"
        echo "  journalctl -u smb -f"
        echo "  tail -f /var/log/nas-proton-sync.log"
        echo ""
        echo "Tailscale:"
        echo "  sudo tailscale status"
        echo "  sudo tailscale ip"
        echo ""
    fi
}

main() {
    check_root

    if [[ "$OUTPUT_JSON" == true ]]; then
        display_json
    else
        display_status
        show_quick_commands
    fi
}

main "$@"
