#!/bin/bash
set -euo pipefail

NAS_MOUNT="/srv/nas"
LUKS_NAME="nas-crypt"
NAS_USER="nas-user"
NAS_KEYFILE="/root/.nas-keyfile"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_warn "This will completely remove the NAS setup"
log_warn "Data will NOT be deleted from the encrypted partition"
read -p "Continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  exit 1
fi

log_info "Stopping and disabling services..."
systemctl stop nas-proton-sync.timer 2>/dev/null || true
systemctl stop nas-snapshot.timer 2>/dev/null || true
systemctl stop nas-health.timer 2>/dev/null || true
systemctl stop syncthing@${NAS_USER}.service 2>/dev/null || true
systemctl disable nas-proton-sync.timer 2>/dev/null || true
systemctl disable nas-snapshot.timer 2>/dev/null || true
systemctl disable nas-health.timer 2>/dev/null || true
systemctl disable syncthing@${NAS_USER}.service 2>/dev/null || true
systemctl disable nas-mount.service 2>/dev/null || true

log_info "Unmounting NAS..."
umount "${NAS_MOUNT}" 2>/dev/null || true

log_info "Closing encrypted partition..."
cryptsetup close "${LUKS_NAME}" 2>/dev/null || true

log_info "Removing systemd files..."
rm -f /etc/systemd/system/nas-*.service
rm -f /etc/systemd/system/nas-*.timer

log_info "Removing utility scripts..."
rm -f /usr/local/bin/nas-*

log_info "Removing configuration..."
rm -rf /etc/nas
rm -rf /var/log/nas

log_info "Removing fstab entry..."
sed -i "\|${NAS_MOUNT}|d" /etc/fstab

log_info "Removing crypttab entry..."
sed -i "\|${LUKS_NAME}|d" /etc/crypttab

log_info "Removing user..."
userdel "${NAS_USER}" 2>/dev/null || true

read -p "Delete keyfile? (yes/no): " del_key
if [[ "$del_key" == "yes" ]]; then
  shred -vfz -n 10 "${NAS_KEYFILE}" 2>/dev/null || true
  log_info "Keyfile securely deleted"
else
  log_warn "Keyfile kept at ${NAS_KEYFILE}"
fi

systemctl daemon-reload

log_info "NAS removal complete!"
log_info "The encrypted partition still exists and can be wiped separately"
log_info "To securely wipe: cryptsetup erase <partition>"
