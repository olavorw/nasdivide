#!/bin/bash
#
# NAS Removal Script for Arch Linux
# Safely removes all NAS components while preserving data option
#
# Usage: sudo ./nas-remove.sh [--keep-data]
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
NAS_USER="nas"
NAS_GROUP="nas"
LUKS_NAME="nas-data"
KEEP_DATA=false

# Parse arguments
for arg in "$@"; do
    case $arg in
        --keep-data)
            KEEP_DATA=true
            shift
            ;;
    esac
done

# Helper functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

confirm_removal() {
    log_warn "================================"
    log_warn "NAS REMOVAL CONFIRMATION"
    log_warn "================================"
    echo ""

    if [[ "$KEEP_DATA" == true ]]; then
        log_info "Mode: KEEP DATA (drive will be unmounted but not wiped)"
    else
        log_error "Mode: FULL REMOVAL (all data will be DESTROYED)"
    fi

    echo ""
    log_info "The following will be removed:"
    echo "  - Systemd services and timers"
    echo "  - Samba configuration"
    echo "  - NAS user and group"
    echo "  - Mount points"
    echo "  - Utility scripts"

    if [[ "$KEEP_DATA" == false ]]; then
        echo "  - LUKS encrypted volume"
        echo "  - ALL DATA on NAS drive"
    fi

    echo ""
    read -p "Type 'remove' to confirm: " confirm
    if [[ "$confirm" != "remove" ]]; then
        log_info "Aborted"
        exit 0
    fi
}

stop_services() {
    log_info "Stopping NAS services..."

    local services=(
        "nas-proton-sync.timer"
        "nas-proton-sync.service"
        "nas-snapshot.timer"
        "nas-snapshot.service"
        "smb"
        "nmb"
    )

    for service in "${services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            systemctl stop "$service" || log_warn "Failed to stop $service"
            log_info "Stopped $service"
        fi
    done

    log_success "Services stopped"
}

disable_services() {
    log_info "Disabling NAS services..."

    local services=(
        "nas-proton-sync.timer"
        "nas-snapshot.timer"
        "smb"
        "nmb"
    )

    for service in "${services[@]}"; do
        if systemctl is-enabled --quiet "$service" 2>/dev/null; then
            systemctl disable "$service" || log_warn "Failed to disable $service"
            log_info "Disabled $service"
        fi
    done

    log_success "Services disabled"
}

remove_systemd_units() {
    log_info "Removing systemd units..."

    local units=(
        "/etc/systemd/system/nas-proton-sync.service"
        "/etc/systemd/system/nas-proton-sync.timer"
        "/etc/systemd/system/nas-snapshot.service"
        "/etc/systemd/system/nas-snapshot.timer"
    )

    for unit in "${units[@]}"; do
        if [[ -f "$unit" ]]; then
            rm "$unit"
            log_info "Removed $unit"
        fi
    done

    systemctl daemon-reload
    log_success "Systemd units removed"
}

unmount_nas() {
    log_info "Unmounting NAS drive..."

    if mountpoint -q "$NAS_MOUNT"; then
        umount "$NAS_MOUNT" || {
            log_error "Failed to unmount $NAS_MOUNT"
            log_info "Trying force unmount..."
            umount -l "$NAS_MOUNT" || {
                log_error "Force unmount failed. Manual intervention required."
                exit 1
            }
        }
        log_success "NAS drive unmounted"
    else
        log_info "NAS drive not mounted"
    fi
}

remove_from_fstab() {
    log_info "Removing NAS entry from /etc/fstab..."

    if grep -q "$NAS_MOUNT" /etc/fstab; then
        sed -i "\|$NAS_MOUNT|d" /etc/fstab
        log_success "Removed from /etc/fstab"
    else
        log_info "No entry in /etc/fstab"
    fi
}

remove_from_crypttab() {
    log_info "Removing NAS entry from /etc/crypttab..."

    if [[ -f /etc/crypttab ]] && grep -q "$LUKS_NAME" /etc/crypttab; then
        sed -i "/$LUKS_NAME/d" /etc/crypttab
        log_success "Removed from /etc/crypttab"
    else
        log_info "No entry in /etc/crypttab"
    fi
}

close_luks() {
    log_info "Closing LUKS container..."

    if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
        cryptsetup close "$LUKS_NAME" || {
            log_error "Failed to close LUKS container"
            exit 1
        }
        log_success "LUKS container closed"
    else
        log_info "LUKS container not open"
    fi
}

wipe_drive() {
    if [[ "$KEEP_DATA" == true ]]; then
        log_info "Skipping drive wipe (--keep-data specified)"
        return
    fi

    log_info "Finding NAS drive..."

    # Try to find the encrypted drive
    local nas_drive=""
    if [[ -e "/dev/mapper/$LUKS_NAME" ]]; then
        nas_drive=$(cryptsetup status "$LUKS_NAME" | grep "device:" | awk '{print $2}')
    fi

    if [[ -z "$nas_drive" ]]; then
        log_warn "Could not automatically detect NAS drive"
        log_info "Available drives:"
        lsblk -d -o NAME,SIZE,TYPE | grep disk
        read -p "Enter drive to wipe (e.g., /dev/sdb) or 'skip': " nas_drive

        if [[ "$nas_drive" == "skip" ]]; then
            log_info "Skipping drive wipe"
            return
        fi
    fi

    if [[ ! -b "$nas_drive" ]]; then
        log_error "Invalid drive: $nas_drive"
        exit 1
    fi

    log_warn "About to wipe $nas_drive - ALL DATA WILL BE LOST"
    read -p "Type 'wipe' to confirm: " confirm
    if [[ "$confirm" != "wipe" ]]; then
        log_info "Skipping drive wipe"
        return
    fi

    log_info "Wiping drive $nas_drive..."
    wipefs -a "$nas_drive"

    log_success "Drive wiped"
}

remove_mount_point() {
    log_info "Removing mount point..."

    if [[ -d "$NAS_MOUNT" ]]; then
        if [[ "$KEEP_DATA" == false ]]; then
            rm -rf "$NAS_MOUNT"
            log_success "Mount point removed"
        else
            log_info "Mount point kept at $NAS_MOUNT"
        fi
    fi
}

remove_nas_user() {
    log_info "Removing NAS user..."

    if id "$NAS_USER" &>/dev/null; then
        # Remove user from any groups
        userdel "$NAS_USER" || log_warn "Failed to remove user"
        log_info "User $NAS_USER removed"
    fi

    if getent group "$NAS_GROUP" &>/dev/null; then
        groupdel "$NAS_GROUP" || log_warn "Failed to remove group"
        log_info "Group $NAS_GROUP removed"
    fi

    log_success "NAS user and group removed"
}

remove_samba_config() {
    log_info "Cleaning up Samba configuration..."

    if [[ -f /etc/samba/smb.conf.backup ]]; then
        log_info "Restoring original Samba config..."
        mv /etc/samba/smb.conf.backup /etc/samba/smb.conf
        log_success "Original config restored"
    else
        log_warn "No backup found. You may need to manually reconfigure Samba."
    fi
}

remove_scripts() {
    log_info "Removing utility scripts..."

    local scripts=(
        "/usr/local/bin/nas-status.sh"
        "/usr/local/bin/nas-backup.sh"
        "/usr/local/bin/nas-proton-sync.sh"
        "/usr/local/bin/nas-snapshot.sh"
    )

    for script in "${scripts[@]}"; do
        if [[ -f "$script" ]]; then
            rm "$script"
            log_info "Removed $script"
        fi
    done

    log_success "Scripts removed"
}

remove_logs() {
    log_info "Removing log files..."

    local logs=(
        "/var/log/nas-proton-sync.log"
        "/var/log/nas-proton-sync.log.old"
    )

    for logfile in "${logs[@]}"; do
        if [[ -f "$logfile" ]]; then
            rm "$logfile"
            log_info "Removed $logfile"
        fi
    done

    log_success "Logs removed"
}

cleanup_rclone() {
    log_info "Cleaning up rclone configuration..."

    log_warn "Proton Drive configuration in ~/.config/rclone/ has NOT been removed"
    log_info "Remove manually if needed: rm -rf /root/.config/rclone/rclone.conf"
}

cleanup_tailscale() {
    log_info "Tailscale configuration..."

    log_warn "Tailscale is still installed and configured"
    log_info "To remove Tailscale completely:"
    echo "  sudo tailscale down"
    echo "  sudo systemctl stop tailscaled"
    echo "  sudo systemctl disable tailscaled"
    echo "  sudo yay -R tailscale"
}

print_summary() {
    echo ""
    log_success "================================"
    log_success "NAS Removal Complete"
    log_success "================================"
    echo ""

    if [[ "$KEEP_DATA" == true ]]; then
        log_info "Data preservation mode was used"
        log_info "The encrypted NAS drive is intact but unmounted"
        log_info "To access the data:"
        echo "  1. Find the drive: lsblk"
        echo "  2. Open LUKS: sudo cryptsetup open /dev/sdX nas-data"
        echo "  3. Mount: sudo mount /dev/mapper/nas-data /mnt"
    else
        log_info "Full removal completed"
        log_info "All NAS data has been destroyed"
    fi

    echo ""
    log_info "Manual cleanup (if desired):"
    echo "  - Remove Tailscale: see above"
    echo "  - Remove rclone config: rm -rf /root/.config/rclone/"
    echo "  - Uninstall packages: yay -R samba rclone btrfs-progs"
}

main() {
    log_info "NAS Removal Script"
    echo ""

    check_root
    confirm_removal

    stop_services
    disable_services
    remove_systemd_units
    unmount_nas
    remove_from_fstab
    remove_from_crypttab
    close_luks
    wipe_drive
    remove_mount_point
    remove_nas_user
    remove_samba_config
    remove_scripts
    remove_logs
    cleanup_rclone
    cleanup_tailscale

    print_summary
}

main "$@"
