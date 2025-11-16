#!/bin/bash
set -euo pipefail

# Configuration
NAS_DRIVE="/dev/sdX" # Change to your NAS drive
NAS_PARTITION="${NAS_DRIVE}1"
NAS_MOUNT="/srv/nas"
NAS_USER="nas-user"
NAS_KEYFILE="/root/.nas-keyfile"
LUKS_NAME="nas-crypt"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  log_error "This script must be run as root"
  exit 1
fi

log_info "Starting NAS setup on Arch Linux..."

# Confirm drive selection
log_warn "This will DESTROY all data on ${NAS_DRIVE}"
read -p "Are you sure? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  log_error "Aborted by user"
  exit 1
fi

# Install required packages
log_info "Installing required packages..."
pacman -S --needed --noconfirm \
  cryptsetup \
  btrfs-progs \
  rclone \
  syncthing \
  tailscale \
  fuse3 \
  lsof \
  rsync \
  aide \
  python-pyinotify

# Partition the drive
log_info "Partitioning ${NAS_DRIVE}..."
parted -s "${NAS_DRIVE}" mklabel gpt
parted -s "${NAS_DRIVE}" mkpart primary 0% 100%
parted -s "${NAS_DRIVE}" set 1 lvm on

# Generate secure random keyfile
log_info "Generating encryption keyfile..."
dd if=/dev/urandom of="${NAS_KEYFILE}" bs=4096 count=1
chmod 600 "${NAS_KEYFILE}"

# Setup LUKS2 encryption with highest security
log_info "Setting up LUKS2 encryption..."
cryptsetup luksFormat \
  --type luks2 \
  --cipher aes-xts-plain64 \
  --key-size 512 \
  --hash sha512 \
  --pbkdf argon2id \
  --iter-time 5000 \
  --use-random \
  "${NAS_PARTITION}" "${NAS_KEYFILE}"

# Open encrypted partition
log_info "Opening encrypted partition..."
cryptsetup open "${NAS_PARTITION}" "${LUKS_NAME}" --key-file="${NAS_KEYFILE}"

# Create BTRFS filesystem with compression
log_info "Creating BTRFS filesystem..."
mkfs.btrfs -L nas-storage "/dev/mapper/${LUKS_NAME}"

# Create mount point
mkdir -p "${NAS_MOUNT}"

# Mount and create subvolumes
mount "/dev/mapper/${LUKS_NAME}" "${NAS_MOUNT}"
btrfs subvolume create "${NAS_MOUNT}/data"
btrfs subvolume create "${NAS_MOUNT}/snapshots"
btrfs subvolume create "${NAS_MOUNT}/sync"
umount "${NAS_MOUNT}"

# Remount with data subvolume
mount -o subvol=data,compress=zstd:3,noatime "/dev/mapper/${LUKS_NAME}" \
  "${NAS_MOUNT}"

# Create necessary directories
mkdir -p "${NAS_MOUNT}"/{shared,backups,sync-state}
mkdir -p /var/log/nas

# Create dedicated NAS user
log_info "Creating NAS user..."
if ! id "${NAS_USER}" &>/dev/null; then
  useradd -r -s /usr/bin/nologin -d "${NAS_MOUNT}" "${NAS_USER}"
fi

# Set permissions
chown -R "${NAS_USER}:${NAS_USER}" "${NAS_MOUNT}"
chmod 750 "${NAS_MOUNT}"

# Setup crypttab for auto-unlock
log_info "Configuring auto-unlock..."
echo "${LUKS_NAME} ${NAS_PARTITION} ${NAS_KEYFILE} luks" >>/etc/crypttab

# Setup fstab
UUID=$(blkid -s UUID -o value "/dev/mapper/${LUKS_NAME}")
echo "UUID=${UUID} ${NAS_MOUNT} btrfs subvol=data,compress=zstd:3,noatime 0 2" \
  >>/etc/fstab

# Create systemd service files
log_info "Creating systemd services..."

# NAS mount service
cat >/etc/systemd/system/nas-mount.service <<'EOF'
[Unit]
Description=NAS Storage Mount
After=cryptsetup.target
Before=nas-sync.service syncthing@nas-user.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/mount /srv/nas
ExecStop=/usr/bin/umount /srv/nas

[Install]
WantedBy=multi-user.target
EOF

# Proton Drive sync service
cat >/etc/systemd/system/nas-proton-sync.service <<'EOF'
[Unit]
Description=NAS Proton Drive Sync
After=network-online.target nas-mount.service
Wants=network-online.target

[Service]
Type=oneshot
User=nas-user
Group=nas-user
ExecStartPre=/usr/local/bin/nas-pre-sync-check
ExecStart=/usr/bin/rclone sync /srv/nas/shared proton:nas-backup \
    --config /etc/nas/rclone.conf \
    --log-file /var/log/nas/proton-sync.log \
    --log-level INFO \
    --fast-list \
    --transfers 4 \
    --checkers 8 \
    --retries 3 \
    --low-level-retries 10 \
    --stats 1m \
    --use-mmap
ExecStartPost=/usr/local/bin/nas-post-sync-check
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Proton Drive sync timer (every 30 minutes)
cat >/etc/systemd/system/nas-proton-sync.timer <<'EOF'
[Unit]
Description=NAS Proton Drive Sync Timer
After=nas-mount.service

[Timer]
OnBootSec=5min
OnUnitActiveSec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Snapshot service
cat >/etc/systemd/system/nas-snapshot.service <<'EOF'
[Unit]
Description=NAS BTRFS Snapshot
After=nas-mount.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-snapshot
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Snapshot timer (every 6 hours)
cat >/etc/systemd/system/nas-snapshot.timer <<'EOF'
[Unit]
Description=NAS Snapshot Timer

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Health monitoring service
cat >/etc/systemd/system/nas-health.service <<'EOF'
[Unit]
Description=NAS Health Monitor
After=nas-mount.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nas-health-check
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

# Health monitoring timer (every hour)
cat >/etc/systemd/system/nas-health.timer <<'EOF'
[Unit]
Description=NAS Health Check Timer

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Create utility scripts directory
mkdir -p /usr/local/bin
mkdir -p /etc/nas

# Create pre-sync check script
cat >/usr/local/bin/nas-pre-sync-check <<'EOF'
#!/bin/bash
set -euo pipefail

MOUNT_POINT="/srv/nas"
SNAPSHOT_DIR="/mnt/nas-root/snapshots"

# Check mount
if ! mountpoint -q "${MOUNT_POINT}"; then
    echo "ERROR: NAS not mounted"
    exit 1
fi

# Check disk space (require at least 5% free)
DISK_USAGE=$(df "${MOUNT_POINT}" | awk 'NR==2 {print $5}' | sed 's/%//')
if [[ ${DISK_USAGE} -gt 95 ]]; then
    echo "ERROR: Disk usage too high: ${DISK_USAGE}%"
    exit 1
fi

# Create pre-sync snapshot
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "${SNAPSHOT_DIR}"

# Mount root to access snapshots subvolume
mount -o subvol=/ /dev/mapper/nas-crypt /mnt/nas-root 2>/dev/null || true
btrfs subvolume snapshot -r "${MOUNT_POINT}" \
    "${SNAPSHOT_DIR}/pre-sync-${TIMESTAMP}"
umount /mnt/nas-root 2>/dev/null || true

echo "Pre-sync check passed. Snapshot created: pre-sync-${TIMESTAMP}"
exit 0
EOF

chmod +x /usr/local/bin/nas-pre-sync-check

# Create post-sync check script
cat >/usr/local/bin/nas-post-sync-check <<'EOF'
#!/bin/bash
set -euo pipefail

LOG_FILE="/var/log/nas/proton-sync.log"
NOTIFICATION_FILE="/var/log/nas/last-sync-status"

# Check last sync status
if tail -n 50 "${LOG_FILE}" | grep -q "ERROR"; then
    echo "FAILED" > "${NOTIFICATION_FILE}"
    echo "WARNING: Sync completed with errors. Check ${LOG_FILE}"
    exit 0
else
    echo "SUCCESS" > "${NOTIFICATION_FILE}"
    date > "${NOTIFICATION_FILE}.timestamp"
    echo "Post-sync check passed"
fi
EOF

chmod +x /usr/local/bin/nas-post-sync-check

# Create snapshot script
cat >/usr/local/bin/nas-snapshot <<'EOF'
#!/bin/bash
set -euo pipefail

MOUNT_POINT="/srv/nas"
SNAPSHOT_DIR="/mnt/nas-root/snapshots"
MAX_SNAPSHOTS=48  # Keep 2 days worth at 6h intervals

# Mount root
mkdir -p /mnt/nas-root
mount -o subvol=/ /dev/mapper/nas-crypt /mnt/nas-root

# Create snapshot
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
btrfs subvolume snapshot -r "${MOUNT_POINT}" \
    "${SNAPSHOT_DIR}/snapshot-${TIMESTAMP}"

echo "Snapshot created: snapshot-${TIMESTAMP}"

# Clean old snapshots
SNAPSHOT_COUNT=$(find "${SNAPSHOT_DIR}" -maxdepth 1 -type d -name "snapshot-*" \
    | wc -l)

if [[ ${SNAPSHOT_COUNT} -gt ${MAX_SNAPSHOTS} ]]; then
    find "${SNAPSHOT_DIR}" -maxdepth 1 -type d -name "snapshot-*" \
        | sort | head -n $((SNAPSHOT_COUNT - MAX_SNAPSHOTS)) \
        | while read snapshot; do
            btrfs subvolume delete "${snapshot}"
            echo "Deleted old snapshot: $(basename ${snapshot})"
        done
fi

umount /mnt/nas-root
EOF

chmod +x /usr/local/bin/nas-snapshot

# Create health check script
cat >/usr/local/bin/nas-health-check <<'EOF'
#!/bin/bash
set -euo pipefail

MOUNT_POINT="/srv/nas"
LOG_FILE="/var/log/nas/health.log"

{
    echo "=== Health Check: $(date) ==="
    
    # Check mount
    if ! mountpoint -q "${MOUNT_POINT}"; then
        echo "CRITICAL: NAS not mounted!"
        exit 1
    fi
    
    # Check BTRFS health
    echo "BTRFS Status:"
    btrfs device stats "${MOUNT_POINT}"
    
    # Check disk space
    echo -e "\nDisk Usage:"
    df -h "${MOUNT_POINT}"
    
    # Check LUKS integrity
    echo -e "\nLUKS Status:"
    cryptsetup status nas-crypt
    
    # Check last sync
    if [[ -f /var/log/nas/last-sync-status.timestamp ]]; then
        LAST_SYNC=$(stat -c %Y /var/log/nas/last-sync-status.timestamp)
        CURRENT=$(date +%s)
        DIFF=$((CURRENT - LAST_SYNC))
        
        if [[ ${DIFF} -gt 7200 ]]; then  # 2 hours
            echo "WARNING: Last successful sync was ${DIFF} seconds ago"
        else
            echo "Last sync: ${DIFF} seconds ago (OK)"
        fi
    fi
    
    echo "=== Health Check Complete ==="
    echo ""
} >> "${LOG_FILE}"

# Keep log size manageable
tail -n 1000 "${LOG_FILE}" > "${LOG_FILE}.tmp"
mv "${LOG_FILE}.tmp" "${LOG_FILE}"

echo "Health check complete. See ${LOG_FILE}"
EOF

chmod +x /usr/local/bin/nas-health-check

# Enable Tailscale
log_info "Enabling Tailscale..."
systemctl enable --now tailscaled

# Enable Syncthing for nas-user
log_info "Setting up Syncthing..."
systemctl enable syncthing@${NAS_USER}.service

# Reload systemd
systemctl daemon-reload

# Enable and start services
log_info "Enabling NAS services..."
systemctl enable nas-mount.service
systemctl enable nas-proton-sync.timer
systemctl enable nas-snapshot.timer
systemctl enable nas-health.timer

# Start mount service
systemctl start nas-mount.service

# Start timers
systemctl start nas-proton-sync.timer
systemctl start nas-snapshot.timer
systemctl start nas-health.timer

# Create rclone config template
cat >/etc/nas/rclone.conf.template <<'EOF'
[proton]
type = protondrive
username = YOUR_PROTON_EMAIL
password = YOUR_PROTON_PASSWORD_OR_APP_PASSWORD
2fa = YOUR_2FA_CODE_IF_ENABLED
EOF

chown root:root /etc/nas/rclone.conf.template
chmod 600 /etc/nas/rclone.conf.template

log_info "Setup complete!"
log_info ""
log_info "Next steps:"
log_info "1. Configure rclone for Proton Drive:"
log_info "   sudo -u ${NAS_USER} rclone config --config /etc/nas/rclone.conf"
log_info "2. Connect to Tailscale:"
log_info "   sudo tailscale up"
log_info "3. Configure Syncthing at http://localhost:8384"
log_info "4. Test sync: systemctl start nas-proton-sync.service"
log_info ""
log_info "Monitor logs:"
log_info "  - Proton sync: /var/log/nas/proton-sync.log"
log_info "  - Health: /var/log/nas/health.log"
log_info "  - Services: journalctl -u nas-*"
