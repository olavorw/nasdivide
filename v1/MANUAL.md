# NAS Setup Guide - Arch Linux

## Architecture

```
Your PC (Arch + Hyprland)
├── Your User → Personal stuff (encrypted 1TB)
└── NAS User → Shared storage
    └── Encrypted Drive → /mnt/nas
        ├── Syncthing (sync between devices)
        ├── Daily backups → Proton Drive
        └── Direct file mirror → Proton Drive
```

## Prerequisites

- Additional drive installed
- Proton Drive account (already have)
- Access to browser for Proton Drive web login (generates encryption keys)

---

## Step 1: Encrypted Drive Setup

### Identify Drive
```bash
lsblk
# Note your drive (e.g., /dev/sda)
```

### Format & Encrypt
```bash
# Replace sdX with your drive
sudo cryptsetup luksFormat /dev/sdX
sudo cryptsetup open /dev/sdX nas_storage
sudo mkfs.ext4 /dev/mapper/nas_storage
```

### Mount
```bash
sudo mkdir -p /mnt/nas
sudo mount /dev/mapper/nas_storage /mnt/nas
```

### Auto-mount on Boot
```bash
# Get UUID
sudo blkid /dev/sdX

# Edit /etc/crypttab
nas_storage UUID=your-uuid-here none luks

# Edit /etc/fstab
/dev/mapper/nas_storage /mnt/nas ext4 defaults 0 2
```

---

## Step 2: Create NAS User

```bash
sudo useradd -m -d /mnt/nas/home/nas -s /bin/zsh nas
sudo passwd nas
sudo chown -R nas:nas /mnt/nas/home/nas
```

Test:
```bash
sudo su - nas
pwd  # Should show /mnt/nas/home/nas
```

---

## Step 3: Syncthing Setup

### Install & Enable
```bash
sudo systemctl enable --now syncthing@nas
```

### Find Ports
```bash
# Web UI port
sudo journalctl -u syncthing@nas | grep "GUI URL"
# Usually: http://localhost:42697

# Sync port
sudo journalctl -u syncthing@nas | grep "tcp://0.0.0.0"
# Example: 33727
```

### UFW Rules (if accessing from network)
```bash
sudo ufw allow 42697/tcp comment "Syncthing NAS UI"
sudo ufw allow 33727/tcp comment "Syncthing NAS sync"
sudo ufw allow 33727/udp comment "Syncthing NAS QUIC"
```

### Configure
- Open `http://localhost:42697`
- Add your PC and laptop as devices
- Create shared folder at `/mnt/nas/sync`

**Your Syncthing Ports:**
- Your user: `localhost:8384`
- NAS user: `localhost:42697`

---

## Step 4: Proton Drive Setup

### Prerequisites
**Important:** Log into https://drive.proton.me via browser first to generate encryption keys.

### Install rclone
```bash
paru -S rclone
```

### Configure
```bash
sudo su - nas
rclone config
```

**Interactive steps:**
```
n) New remote
name> remote

Storage> protondrive

Username> your@proton.email

Password> [your proton password]

2FA> [6-digit code if enabled, or leave blank]
```

### Test Connection
```bash
# Wait if IP blocked (~30-60 min)
rclone ls remote:

# Create folders
rclone mkdir remote:backup
rclone mkdir remote:files

# Test upload
echo "test" > test.txt
rclone copy test.txt remote:files/
rclone ls remote:files/
rm test.txt
```

---

## Step 5: Restic Backup Setup

### Install
```bash
paru -S restic
```

### Initialize Repository
```bash
sudo su - nas
restic init --repo rclone:remote:backup
# Create strong password, save it!
```

### Save Password
```bash
echo "your_restic_password" > ~/.restic_password
chmod 600 ~/.restic_password
```

### Test Backup
```bash
# Create test data
mkdir -p /mnt/nas/sync
echo "test backup" > /mnt/nas/sync/test.txt

# Backup
restic -r rclone:remote:backup --password-file ~/.restic_password backup /mnt/nas/sync

# List snapshots
restic -r rclone:remote:backup --password-file ~/.restic_password snapshots
```

---

## Step 6: Automated Backups

### Backup Script
```bash
sudo nano /usr/local/bin/nas-backup.sh
```

```bash
#!/bin/bash
export RESTIC_REPOSITORY="rclone:remote:backup"
export RESTIC_PASSWORD_FILE="/mnt/nas/home/nas/.restic_password"

# Direct file sync (browsable in Proton Drive)
rclone sync /mnt/nas/sync remote:files

# Versioned backup (snapshots)
restic backup /mnt/nas/sync

# Keep: 7 daily, 4 weekly, 6 monthly
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

```bash
sudo chmod +x /usr/local/bin/nas-backup.sh
sudo chown nas:nas /usr/local/bin/nas-backup.sh
```

### Systemd Service
```bash
sudo nano /etc/systemd/system/nas-backup.service
```

```ini
[Unit]
Description=NAS Backup to Proton Drive
After=network-online.target

[Service]
Type=oneshot
User=nas
ExecStart=/usr/local/bin/nas-backup.sh
```

### Systemd Timer
```bash
sudo nano /etc/systemd/system/nas-backup.timer
```

```ini
[Unit]
Description=Run NAS backup daily

[Timer]
OnCalendar=daily
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
```

### Enable & Test
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now nas-backup.timer

# Check status
sudo systemctl status nas-backup.timer
systemctl list-timers

# Test manually
sudo systemctl start nas-backup.service
sudo journalctl -u nas-backup.service -f
```

---

## Optional: Remote Access (Tailscale)

### Install
```bash
paru -S tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

### UFW Rule
```bash
sudo ufw allow in on tailscale0
```

### Access
- Syncthing: `http://tailscale-ip:42697`
- System-wide VPN (all users)

---

## Proton Drive Structure

```
remote:files/          → Direct files (browsable via web/app)
remote:backup/         → Restic snapshots (restore only)
  ├── config
  ├── data/
  ├── index/
  ├── keys/
  └── snapshots/
```

**Access:**
- `remote:files` → Browse in Proton Drive app/web
- `remote:backup` → Use `restic restore` command

---

## Useful Commands

### Syncthing
```bash
# Status
sudo systemctl status syncthing@nas

# Logs
sudo journalctl -u syncthing@nas -f

# Restart
sudo systemctl restart syncthing@nas
```

### Backups
```bash
# Manual backup
sudo systemctl start nas-backup.service

# View logs
sudo journalctl -u nas-backup.service

# List snapshots
sudo -u nas restic -r rclone:remote:backup --password-file /mnt/nas/home/nas/.restic_password snapshots

# Restore latest
sudo -u nas restic -r rclone:remote:backup restore latest --target /restore/path
```

### rclone
```bash
# List files
rclone ls remote:files

# Sync manually
rclone sync /mnt/nas/sync remote:files -v

# Check quota
rclone about remote:
```

### Drive Management
```bash
# Check mounts
df -h

# Unmount
sudo umount /mnt/nas
sudo cryptsetup close nas_storage

# Remount
sudo cryptsetup open /dev/sdX nas_storage
sudo mount /dev/mapper/nas_storage /mnt/nas
```

---

## Troubleshooting

### Proton IP Block
- Wait 30-60 minutes
- Disable VPN temporarily
- Log into Proton Drive via browser first
- Contact: https://proton.me/support/appeal-abuse

### Syncthing Not Syncing
- Check both devices connected in UI
- Verify firewall rules (UFW)
- Check folder permissions (`chown nas:nas`)

### Backup Fails
- Test rclone connection: `rclone ls remote:`
- Check restic password file exists and is readable
- View logs: `sudo journalctl -u nas-backup.service`

### Mount Issues
- Check `/etc/crypttab` UUID matches `blkid`
- Ensure `/etc/fstab` has correct mapper path
- Test manual mount first

---

## Summary

**What Runs:**
- Syncthing@nas (24/7) → Syncs files between devices
- nas-backup.timer → Daily at 3 AM

**Storage:**
- `/mnt/nas/sync` → Synced folder
- `remote:files` → Direct mirror (browsable)
- `remote:backup` → Versioned snapshots

**Users:**
- Your user → Personal system (port 8384)
- NAS user → Shared storage (port 42697)

**Security:**
- LUKS encrypted drive
- Proton Drive E2E encryption
- Restic encrypted backups
- Separate user isolation