# Arch Linux Modular NAS Setup

A secure, autonomous, and modular Network Attached Storage (NAS) system for Arch Linux that operates alongside your personal system.

## Overview

This setup provides:
- **Full Disk Encryption** (LUKS2 with TPM2 auto-unlock)
- **Btrfs Filesystem** (with compression, snapshots, and data integrity)
- **Autonomous Operation** (no manual intervention needed)
- **Proton Drive Integration** (encrypted cloud backup)
- **Tailscale Networking** (secure remote access)
- **Complete Modularity** (easy to add or remove)

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Your Arch System                      │
├─────────────────────────────────────────────────────────┤
│  Drive 1 (Personal)        │  Drive 2 (NAS)             │
│  ├─ /boot                  │  └─ LUKS2 Encrypted        │
│  ├─ / (encrypted)          │     └─ Btrfs Filesystem    │
│  └─ /home/user             │        └─ /srv/nas         │
│                            │           ├─ data/          │
│                            │           ├─ shares/        │
│                            │           └─ .snapshots/    │
├─────────────────────────────────────────────────────────┤
│  Services                                                │
│  ├─ Samba (file sharing over Tailscale)                │
│  ├─ Proton Drive Sync (daily backup)                   │
│  ├─ Btrfs Snapshots (hourly)                           │
│  └─ Tailscale (secure mesh network)                    │
└─────────────────────────────────────────────────────────┘
```

## Security Features

### Encryption
- **LUKS2** with Argon2id key derivation
- **AES-XTS-Plain64** cipher (512-bit keys)
- **SHA-512** hashing
- **TPM2 Auto-unlock** (no password needed after boot, but secure)
- **Fallback password** protection

### Network Security
- **Tailscale** mesh networking (WireGuard-based)
- **SMB3** with mandatory encryption
- **No port forwarding** required
- **Access restricted** to Tailscale network only

### Data Integrity
- **Btrfs checksums** (SHA-256) for all data
- **Hourly snapshots** (24 retained)
- **Daily Proton Drive backup** (encrypted)
- **Copy-on-Write** (CoW) prevents data corruption
- **Automatic verification** on restore

### User Isolation
- Dedicated `nas` system user (no login)
- Strict file permissions (750/770)
- Service runs with minimal privileges
- Personal user isolated from NAS data

## Prerequisites

- Arch Linux system (already set up)
- Second drive for NAS storage (will be wiped)
- Internet connection
- Root access
- TPM2 chip (optional, for auto-unlock)

## Quick Start

### 1. Initial Setup

```bash
# Make scripts executable
chmod +x nas-*.sh

# Run setup (replace /dev/sdX with your NAS drive)
sudo ./nas-setup.sh /dev/sdX
```

**WARNING:** This will **destroy all data** on the specified drive!

### 2. Configure Proton Drive

```bash
# Launch rclone configuration
sudo rclone config

# Follow prompts:
# - Choose "n" for new remote
# - Name: proton-nas
# - Storage: Choose "Proton Drive"
# - Follow authentication steps
```

### 3. Configure Tailscale

```bash
# Authenticate with Tailscale
sudo tailscale up

# Get your Tailscale IP
sudo tailscale ip

# Optional: Update Samba to only listen on Tailscale
# Edit /etc/samba/smb.conf and add:
#   interfaces = tailscale0
#   bind interfaces only = yes
```

### 4. Add Users to Samba

```bash
# Add your personal user to NAS group
sudo usermod -aG nas $USER

# Set Samba password for your user
sudo smbpasswd -a $USER

# Enable your Samba user
sudo smbpasswd -e $USER
```

### 5. Test the Setup

```bash
# Check status
sudo ./nas-status.sh

# Run manual backup
sudo ./nas-backup.sh --verify

# Create test file
echo "Hello NAS" | sudo tee /srv/nas/data/test.txt

# From another device on Tailscale, connect:
# smb://<tailscale-ip>/nas-data
```

## Usage

### Check System Status

```bash
sudo ./nas-status.sh

# Output JSON format
sudo ./nas-status.sh --json
```

### Manual Backup

```bash
# Basic backup
sudo ./nas-backup.sh

# Backup with pre-backup snapshot
sudo ./nas-backup.sh --snapshot

# Backup with verification
sudo ./nas-backup.sh --verify

# Dry run (test without uploading)
sudo ./nas-backup.sh --dry-run
```

### Access NAS Files

#### From Local Machine
```bash
# Direct access (as root or nas group member)
cd /srv/nas/data

# Via Samba locally
smbclient //localhost/nas-data -U $USER
```

#### From Remote Device (over Tailscale)
```bash
# Linux/Mac
smbclient //<tailscale-ip>/nas-data -U $USER

# Or mount it
sudo mount -t cifs //<tailscale-ip>/nas-data /mnt -o username=$USER

# Windows
# File Explorer: \\<tailscale-ip>\nas-data
```

### Manage Snapshots

```bash
# List snapshots
sudo ls -lh /srv/nas/.snapshots/

# Restore from snapshot
sudo cp -r /srv/nas/.snapshots/data-20250115-120000/myfile.txt /srv/nas/data/

# Manual snapshot
sudo /usr/local/bin/nas-snapshot.sh
```

### View Logs

```bash
# Proton Drive sync log
sudo tail -f /var/log/nas-proton-sync.log

# Samba logs
sudo journalctl -u smb -f

# Snapshot logs
sudo journalctl -u nas-snapshot.service -f

# System logs
sudo journalctl -xe
```

## Automatic Operations

The NAS runs these tasks automatically:

| Task | Frequency | Service |
|------|-----------|---------|
| Btrfs Snapshots | Hourly | nas-snapshot.timer |
| Proton Drive Sync | Daily (24h) | nas-proton-sync.timer |
| Filesystem Checks | On mount | systemd |

### Customize Schedule

Edit timer files in `/etc/systemd/system/`:

```bash
# Change Proton Drive sync to every 6 hours
sudo systemctl edit nas-proton-sync.timer

# Add:
[Timer]
OnUnitActiveSec=6h

# Reload and restart
sudo systemctl daemon-reload
sudo systemctl restart nas-proton-sync.timer
```

## Maintenance

### Check Filesystem Health

```bash
# Btrfs device statistics
sudo btrfs device stats /srv/nas

# Filesystem usage
sudo btrfs filesystem usage /srv/nas

# Scrub (verify all data)
sudo btrfs scrub start /srv/nas
sudo btrfs scrub status /srv/nas
```

### Balance Filesystem

```bash
# Balance (rebalance data allocation)
sudo btrfs balance start -dusage=50 /srv/nas
```

### Manual Proton Drive Operations

```bash
# List remote files
sudo rclone ls proton-nas:NAS-Backup

# Download specific file
sudo rclone copy proton-nas:NAS-Backup/myfile.txt /tmp/

# Check sync status
sudo rclone check /srv/nas/data proton-nas:NAS-Backup
```

## Removal

### Option 1: Keep Data

```bash
# Remove all NAS services but keep encrypted drive intact
sudo ./nas-remove.sh --keep-data

# Later, to access data:
sudo cryptsetup open /dev/sdX nas-data
sudo mount /dev/mapper/nas-data /mnt
```

### Option 2: Complete Removal

```bash
# Remove everything including data
sudo ./nas-remove.sh

# This will:
# - Stop all services
# - Unmount drive
# - Close LUKS container
# - Wipe the drive
# - Remove all configurations
```

## Troubleshooting

### NAS Won't Mount on Boot

```bash
# Check if LUKS container is open
ls /dev/mapper/nas-data

# If not, open manually
sudo cryptsetup open /dev/sdX nas-data

# Then mount
sudo mount /dev/mapper/nas-data /srv/nas

# Check TPM2 enrollment
sudo systemd-cryptenroll /dev/sdX
```

### Proton Drive Sync Fails

```bash
# Check rclone configuration
sudo rclone config show

# Test connection
sudo rclone lsd proton-nas:

# Check logs
sudo journalctl -u nas-proton-sync.service -n 50

# Re-run sync manually
sudo /usr/local/bin/nas-proton-sync.sh
```

### Cannot Access via Samba

```bash
# Check Samba status
sudo systemctl status smb

# Restart Samba
sudo systemctl restart smb nmb

# Check firewall
sudo firewall-cmd --list-all
# or
sudo ufw status

# Test locally first
smbclient //localhost/nas-data -U $USER

# Check Tailscale connection
tailscale status
```

### Btrfs Errors

```bash
# Check for errors
sudo btrfs device stats /srv/nas

# Run scrub to detect/repair
sudo btrfs scrub start /srv/nas
sudo btrfs scrub status /srv/nas

# Check dmesg for hardware issues
sudo dmesg | grep -i btrfs
```

### Out of Space

```bash
# Check usage
df -h /srv/nas
sudo btrfs filesystem usage /srv/nas

# Clean old snapshots
sudo ls /srv/nas/.snapshots/
sudo btrfs subvolume delete /srv/nas/.snapshots/old-snapshot-name

# Balance filesystem
sudo btrfs balance start -dusage=50 /srv/nas

# Enable more aggressive compression
sudo mount -o remount,compress=zstd:9 /srv/nas
```

## Advanced Configuration

### Enable Scrub on Schedule

```bash
# Create monthly scrub timer
sudo tee /etc/systemd/system/btrfs-scrub@.service << 'EOF'
[Unit]
Description=Btrfs scrub on %f

[Service]
Type=oneshot
ExecStart=/usr/bin/btrfs scrub start -B %f
EOF

sudo tee /etc/systemd/system/btrfs-scrub@.timer << 'EOF'
[Unit]
Description=Monthly Btrfs scrub on %f

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Enable for NAS
sudo systemctl enable --now btrfs-scrub@srv-nas.timer
```

### Increase Proton Drive Upload Speed

Edit `/usr/local/bin/nas-proton-sync.sh`:

```bash
# Change transfers from 4 to 8
--transfers 8 \
--checkers 16 \
```

### Add Additional Samba Shares

Edit `/etc/samba/smb.conf`:

```ini
[media]
    path = /srv/nas/data/media
    browseable = yes
    writable = yes
    valid users = @nas
    create mask = 0660
    directory mask = 0770
```

Then restart Samba:
```bash
sudo systemctl restart smb
```

### Setup Email Notifications

Install `s-nail`:
```bash
sudo yay -S s-nail
```

Add to sync script at `/usr/local/bin/nas-proton-sync.sh`:

```bash
# On failure, send email
if [ $? -ne 0 ]; then
    echo "NAS backup failed at $(date)" | mail -s "NAS Backup Failed" you@example.com
fi
```

## Performance Tuning

### Optimize for SSD

```bash
# Remount with SSD options
sudo mount -o remount,ssd,discard=async /srv/nas

# Make permanent in /etc/fstab
# Add: ssd,discard=async to mount options
```

### Optimize for HDD

```bash
# Remount with HDD options
sudo mount -o remount,autodefrag /srv/nas
```

### Compression Levels

```bash
# Maximum compression (slower writes, more CPU)
sudo mount -o remount,compress=zstd:15 /srv/nas

# Faster compression (less CPU)
sudo mount -o remount,compress=zstd:1 /srv/nas

# Balanced (default)
sudo mount -o remount,compress=zstd:3 /srv/nas
```

## Security Recommendations

1. **Backup LUKS Header**
   ```bash
   sudo cryptsetup luksHeaderBackup /dev/sdX --header-backup-file /secure/location/nas-header.img
   ```

2. **Store Recovery Key Offline**
   - Write down your LUKS password
   - Store in secure physical location
   - Do NOT store on the NAS itself

3. **Regular Security Audits**
   ```bash
   # Check for failed login attempts
   sudo journalctl -u smb | grep -i failed

   # Monitor active connections
   sudo smbstatus
   ```

4. **Update Regularly**
   ```bash
   sudo yay -Syu
   ```

5. **Enable Firewall**
   ```bash
   sudo yay -S firewalld
   sudo systemctl enable --now firewalld
   sudo firewall-cmd --permanent --add-service=samba
   sudo firewall-cmd --reload
   ```

## FAQ

**Q: Can I use this with existing data on the second drive?**
A: No, the setup script will wipe the drive. Backup your data first.

**Q: What happens if my TPM2 fails?**
A: You can still unlock using your LUKS password. Always keep it in a secure location.

**Q: How much space does Proton Drive backup use?**
A: Only the actual data in `/srv/nas/data` is backed up (snapshots are excluded). It uses incremental sync, so subsequent backups are fast.

**Q: Can I access the NAS without Tailscale?**
A: Yes, edit `/etc/samba/smb.conf` and remove the interface restrictions. But this is less secure.

**Q: Does this work with ZFS instead of Btrfs?**
A: The scripts are designed for Btrfs, but you can manually adapt for ZFS.

**Q: How do I increase snapshot retention?**
A: Edit `/usr/local/bin/nas-snapshot.sh` and change `RETENTION_HOURLY=24` to your desired value.

**Q: Can I run this on other Linux distros?**
A: The scripts are Arch-specific (use `yay`), but can be adapted for other distros by changing package management commands.

## File Structure

```
/srv/nas/                    # NAS root
├── data/                    # Main NAS storage (your files go here)
├── shares/                  # Additional shares (optional)
├── backup/                  # Local backup area
└── .snapshots/              # Btrfs snapshots
    ├── data-20250115-120000/  # Hourly snapshots
    └── data-backup-*/         # Manual backup snapshots

/usr/local/bin/              # Utility scripts
├── nas-status.sh            # Status checker
├── nas-backup.sh            # Manual backup
├── nas-proton-sync.sh       # Proton Drive sync
└── nas-snapshot.sh          # Snapshot creation

/etc/systemd/system/         # Service definitions
├── nas-proton-sync.service
├── nas-proton-sync.timer
├── nas-snapshot.service
└── nas-snapshot.timer

/var/log/                    # Logs
└── nas-proton-sync.log      # Proton Drive sync log
```

## Contributing

This is a personal setup script, but feel free to adapt it for your needs.

## License

MIT License - Use at your own risk

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review system logs: `journalctl -xe`
3. Check service status: `systemctl status smb nas-proton-sync.timer`

---

**Created for maximum security, convenience, and modularity on Arch Linux**
