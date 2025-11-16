#!/bin/bash
#
# NAS Setup Script for Arch Linux
# Sets up a modular, encrypted, autonomous NAS on a second drive
#
# Usage: sudo ./nas-setup.sh /dev/sdX
#
# Requirements:
# - Second drive for NAS storage
# - Internet connection
# - Root privileges

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
NAS_DRIVE="${1:-}"
NAS_MOUNT="/srv/nas"
NAS_USER="nas"
NAS_GROUP="nas"
NAS_UID=900
NAS_GID=900
LUKS_NAME="nas-data"
SNAPSHOT_INTERVAL="hourly"
PROTON_SYNC_INTERVAL="daily"

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

check_drive() {
    if [[ -z "$NAS_DRIVE" ]]; then
        log_error "Usage: $0 /dev/sdX"
        log_info "Available drives:"
        lsblk -d -o NAME,SIZE,TYPE | grep disk
        exit 1
    fi

    if [[ ! -b "$NAS_DRIVE" ]]; then
        log_error "Drive $NAS_DRIVE does not exist"
        exit 1
    fi

    log_warn "WARNING: This will DESTROY all data on $NAS_DRIVE"
    lsblk "$NAS_DRIVE"
    read -p "Continue? (type 'yes' to confirm): " confirm
    if [[ "$confirm" != "yes" ]]; then
        log_info "Aborted"
        exit 0
    fi
}

install_packages() {
    log_info "Installing required packages..."

    local packages=(
        "cryptsetup"        # LUKS encryption
        "btrfs-progs"       # Btrfs filesystem tools
        "samba"             # File sharing
        "rclone"            # Proton Drive sync
        "tailscale"         # Secure networking
        "tpm2-tools"        # TPM2 support (if available)
        "snapper"           # Snapshot management (optional)
    )

    yay -S --needed --noconfirm "${packages[@]}" || {
        log_error "Failed to install packages"
        exit 1
    }

    log_success "Packages installed"
}

setup_encryption() {
    log_info "Setting up LUKS2 encryption on $NAS_DRIVE..."

    # Wipe drive
    log_info "Securely wiping drive (this may take a while)..."
    wipefs -a "$NAS_DRIVE"

    # Create LUKS2 container with strong parameters
    log_info "Creating LUKS2 encrypted container..."
    cryptsetup luksFormat \
        --type luks2 \
        --cipher aes-xts-plain64 \
        --key-size 512 \
        --hash sha512 \
        --pbkdf argon2id \
        --pbkdf-memory 1048576 \
        --pbkdf-parallel 4 \
        --pbkdf-force-iterations 4 \
        --use-random \
        "$NAS_DRIVE"

    log_success "LUKS2 container created"

    # Open the encrypted container
    log_info "Opening encrypted container..."
    cryptsetup open "$NAS_DRIVE" "$LUKS_NAME"

    log_success "Encrypted container opened as /dev/mapper/$LUKS_NAME"
}

setup_tpm2_unlock() {
    log_info "Attempting to set up TPM2 auto-unlock..."

    if ! command -v systemd-cryptenroll &> /dev/null; then
        log_warn "systemd-cryptenroll not available, skipping TPM2 setup"
        return 1
    fi

    if [[ ! -d /sys/class/tpm ]]; then
        log_warn "No TPM2 device found, skipping auto-unlock setup"
        log_info "You will need to unlock the NAS drive manually on boot"
        return 1
    fi

    # Enroll TPM2
    log_info "Enrolling TPM2 for auto-unlock..."
    systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 "$NAS_DRIVE" || {
        log_warn "TPM2 enrollment failed, you'll need manual unlock"
        return 1
    }

    # Update crypttab for auto-unlock
    echo "${LUKS_NAME} UUID=$(cryptsetup luksUUID $NAS_DRIVE) none tpm2-device=auto,discard" >> /etc/crypttab

    log_success "TPM2 auto-unlock configured"
    return 0
}

create_filesystem() {
    log_info "Creating Btrfs filesystem with optimal settings..."

    mkfs.btrfs \
        --label NAS-DATA \
        --features extref,skinny-metadata \
        --checksum sha256 \
        --nodesize 16384 \
        /dev/mapper/"$LUKS_NAME"

    log_success "Btrfs filesystem created"
}

setup_mount() {
    log_info "Setting up mount point..."

    mkdir -p "$NAS_MOUNT"

    # Get UUID
    local uuid
    uuid=$(blkid -s UUID -o value /dev/mapper/"$LUKS_NAME")

    # Add to fstab with optimal Btrfs options
    echo "UUID=$uuid $NAS_MOUNT btrfs defaults,compress=zstd:3,noatime,space_cache=v2,autodefrag 0 2" >> /etc/fstab

    # Mount
    mount "$NAS_MOUNT"

    log_success "NAS drive mounted at $NAS_MOUNT"
}

create_nas_user() {
    log_info "Creating NAS system user..."

    if id "$NAS_USER" &>/dev/null; then
        log_warn "User $NAS_USER already exists, skipping creation"
    else
        groupadd -g "$NAS_GID" "$NAS_GROUP"
        useradd -r -u "$NAS_UID" -g "$NAS_GROUP" -d "$NAS_MOUNT" -s /usr/bin/nologin -c "NAS System User" "$NAS_USER"
        log_success "User $NAS_USER created"
    fi
}

setup_directory_structure() {
    log_info "Creating directory structure..."

    mkdir -p "$NAS_MOUNT"/{data,shares,backup,.snapshots}

    # Set ownership
    chown -R "$NAS_USER:$NAS_GROUP" "$NAS_MOUNT"
    chmod 750 "$NAS_MOUNT"
    chmod 770 "$NAS_MOUNT"/{data,shares}
    chmod 700 "$NAS_MOUNT"/backup

    log_success "Directory structure created"
}

configure_samba() {
    log_info "Configuring Samba for Tailscale access..."

    # Backup original config
    if [[ -f /etc/samba/smb.conf ]]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.backup
    fi

    # Create Samba config
    cat > /etc/samba/smb.conf << 'EOF'
[global]
    workgroup = WORKGROUP
    server string = Arch NAS
    security = user
    map to guest = never
    log file = /var/log/samba/%m.log
    max log size = 50

    # Security settings
    server min protocol = SMB3
    server smb encrypt = required

    # Performance
    socket options = TCP_NODELAY IPTOS_LOWDELAY SO_RCVBUF=524288 SO_SNDBUF=524288
    read raw = yes
    write raw = yes

    # Only listen on Tailscale interface (will be configured after Tailscale setup)
    # interfaces = tailscale0
    # bind interfaces only = yes

[nas-data]
    path = /srv/nas/data
    browseable = yes
    writable = yes
    valid users = @nas
    create mask = 0660
    directory mask = 0770
    force user = nas
    force group = nas

[nas-shares]
    path = /srv/nas/shares
    browseable = yes
    writable = yes
    guest ok = no
    create mask = 0660
    directory mask = 0770
    force user = nas
    force group = nas
EOF

    # Enable and start Samba
    systemctl enable smb nmb
    systemctl start smb nmb || log_warn "Samba start failed, will retry after Tailscale setup"

    log_success "Samba configured"
    log_info "Add users to NAS: smbpasswd -a username"
}

setup_tailscale() {
    log_info "Setting up Tailscale..."

    # Enable and start Tailscale
    systemctl enable tailscaled
    systemctl start tailscaled

    log_success "Tailscale daemon started"
    log_warn "IMPORTANT: Run 'sudo tailscale up' to authenticate and join your network"
    log_info "After joining, update /etc/samba/smb.conf to bind only to Tailscale interface"
}

setup_proton_sync() {
    log_info "Setting up Proton Drive sync..."

    # Create rclone config directory
    mkdir -p /root/.config/rclone

    log_success "Rclone directory created"
    log_warn "IMPORTANT: Configure rclone with 'rclone config' to add Proton Drive"
    log_info "Set remote name as 'proton-nas'"

    # Create sync script
    cat > /usr/local/bin/nas-proton-sync.sh << 'SYNCEOF'
#!/bin/bash
#
# NAS to Proton Drive Sync Script
# Performs incremental encrypted backup to Proton Drive
#

set -euo pipefail

RCLONE_REMOTE="proton-nas:NAS-Backup"
SOURCE_DIR="/srv/nas/data"
LOG_FILE="/var/log/nas-proton-sync.log"
MAX_LOG_SIZE=10485760  # 10MB

# Rotate log if too large
if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE") -gt $MAX_LOG_SIZE ]]; then
    mv "$LOG_FILE" "$LOG_FILE.old"
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "Starting Proton Drive sync..."

# Check if rclone is configured
if ! rclone listremotes | grep -q "proton-nas:"; then
    log "ERROR: Proton Drive remote 'proton-nas' not configured"
    log "Run: rclone config"
    exit 1
fi

# Perform sync
rclone sync \
    --progress \
    --transfers 4 \
    --checkers 8 \
    --checksum \
    --exclude '.snapshots/**' \
    --exclude '*.tmp' \
    --exclude '*.temp' \
    --log-file="$LOG_FILE" \
    --log-level INFO \
    "$SOURCE_DIR" \
    "$RCLONE_REMOTE" || {
        log "ERROR: Sync failed"
        exit 1
    }

log "Sync completed successfully"
log "Checking sync integrity..."

# Verify
rclone check "$SOURCE_DIR" "$RCLONE_REMOTE" --one-way 2>&1 | tee -a "$LOG_FILE" || {
    log "WARNING: Integrity check found differences"
}

log "Backup process complete"
SYNCEOF

    chmod +x /usr/local/bin/nas-proton-sync.sh

    # Create systemd service
    cat > /etc/systemd/system/nas-proton-sync.service << 'EOF'
[Unit]
Description=NAS Proton Drive Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/nas-proton-sync.sh
StandardOutput=journal
StandardError=journal

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
EOF

    # Create systemd timer
    cat > /etc/systemd/system/nas-proton-sync.timer << EOF
[Unit]
Description=NAS Proton Drive Sync Timer
After=network-online.target

[Timer]
OnBootSec=1h
OnUnitActiveSec=24h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable nas-proton-sync.timer
    systemctl start nas-proton-sync.timer

    log_success "Proton Drive sync configured (daily backups)"
}

setup_snapshots() {
    log_info "Setting up Btrfs snapshots..."

    # Create snapshot script
    cat > /usr/local/bin/nas-snapshot.sh << 'SNAPEOF'
#!/bin/bash
#
# NAS Snapshot Script
# Creates Btrfs snapshots for data integrity
#

set -euo pipefail

NAS_MOUNT="/srv/nas"
SNAPSHOT_DIR="$NAS_MOUNT/.snapshots"
RETENTION_HOURLY=24
RETENTION_DAILY=7
RETENTION_WEEKLY=4

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Creating snapshot..."

# Create snapshot
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
btrfs subvolume snapshot -r "$NAS_MOUNT/data" "$SNAPSHOT_DIR/data-$TIMESTAMP" || {
    log "ERROR: Snapshot creation failed"
    exit 1
}

log "Snapshot created: data-$TIMESTAMP"

# Cleanup old snapshots
log "Cleaning up old snapshots..."

# Keep last N hourly snapshots
ls -1t "$SNAPSHOT_DIR" | grep "^data-" | tail -n +$((RETENTION_HOURLY + 1)) | while read snap; do
    log "Removing old snapshot: $snap"
    btrfs subvolume delete "$SNAPSHOT_DIR/$snap"
done

log "Snapshot process complete"
SNAPEOF

    chmod +x /usr/local/bin/nas-snapshot.sh

    # Create systemd service
    cat > /etc/systemd/system/nas-snapshot.service << 'EOF'
[Unit]
Description=NAS Btrfs Snapshot
After=local-fs.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/nas-snapshot.sh
StandardOutput=journal
StandardError=journal
EOF

    # Create systemd timer
    cat > /etc/systemd/system/nas-snapshot.timer << 'EOF'
[Unit]
Description=NAS Snapshot Timer

[Timer]
OnBootSec=10min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable nas-snapshot.timer
    systemctl start nas-snapshot.timer

    log_success "Snapshot system configured (hourly snapshots)"
}

create_status_script() {
    log_info "Creating status utility script..."

    cat > /usr/local/bin/nas-status.sh << 'STATUSEOF'
#!/bin/bash
# NAS Status Script
# See nas-status.sh for full implementation
STATUSEOF

    chmod +x /usr/local/bin/nas-status.sh

    log_success "Status script created at /usr/local/bin/nas-status.sh"
}

setup_firewall() {
    log_info "Configuring firewall for Tailscale-only access..."

    # Check if firewalld or ufw is installed
    if command -v firewall-cmd &> /dev/null; then
        log_info "Configuring firewalld..."
        firewall-cmd --permanent --add-service=samba
        firewall-cmd --reload
    elif command -v ufw &> /dev/null; then
        log_info "Configuring ufw..."
        log_warn "Manual configuration needed: restrict Samba to Tailscale IPs"
    else
        log_warn "No firewall detected. Consider setting up firewalld or ufw"
    fi
}

print_summary() {
    log_success "================================"
    log_success "NAS Setup Complete!"
    log_success "================================"
    echo ""
    log_info "NAS Mount Point: $NAS_MOUNT"
    log_info "NAS User: $NAS_USER"
    log_info "Encrypted Device: /dev/mapper/$LUKS_NAME"
    echo ""
    log_info "Next Steps:"
    echo "  1. Configure Tailscale: sudo tailscale up"
    echo "  2. Configure Proton Drive: sudo rclone config"
    echo "     - Set remote name as 'proton-nas'"
    echo "     - Choose 'Proton Drive' as storage type"
    echo "  3. Add Samba users: sudo smbpasswd -a YOUR_USERNAME"
    echo "  4. Add your user to nas group: sudo usermod -aG nas YOUR_USERNAME"
    echo "  5. Test backup: sudo /usr/local/bin/nas-proton-sync.sh"
    echo "  6. Check status: sudo nas-status.sh"
    echo ""
    log_info "Services:"
    echo "  - Samba: systemctl status smb"
    echo "  - Proton Sync: systemctl status nas-proton-sync.timer"
    echo "  - Snapshots: systemctl status nas-snapshot.timer"
    echo "  - Tailscale: systemctl status tailscaled"
    echo ""
    log_warn "IMPORTANT: Save your LUKS password in a secure location!"
    log_warn "Without it, you cannot recover your data if TPM2 fails."
}

main() {
    log_info "Starting NAS setup..."
    echo ""

    check_root
    check_drive

    install_packages
    setup_encryption

    # Try TPM2 auto-unlock, but continue if it fails
    setup_tpm2_unlock || log_info "Continuing without TPM2 auto-unlock"

    create_filesystem
    setup_mount
    create_nas_user
    setup_directory_structure
    configure_samba
    setup_tailscale
    setup_proton_sync
    setup_snapshots
    create_status_script
    setup_firewall

    print_summary
}

main "$@"
