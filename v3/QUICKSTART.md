# Quick Start Guide

Get your NAS up and running in **15 minutes**.

## Prerequisites Checklist

- [ ] Arch Linux system (working)
- [ ] Second drive for NAS (will be **wiped**)
- [ ] Internet connection
- [ ] Root/sudo access

## Step-by-Step Setup

### 1. Identify Your NAS Drive (2 min)

```bash
# List all drives
lsblk -d -o NAME,SIZE,TYPE,MOUNTPOINT | grep disk

# Example output:
# sda   500G disk          <- This is your main system
# sdb   1T   disk          <- This will be your NAS
```

**⚠️ WARNING**: The next step will **permanently erase** all data on the drive you select!

### 2. Run Setup Script (10 min)

```bash
# Navigate to script directory
cd /home/olavorw/Projects/nasDivide/nasdivide/v3

# Run setup (replace /dev/sdb with your NAS drive)
sudo ./nas-setup.sh /dev/sdb
```

**What happens during setup:**
1. Installs required packages (cryptsetup, btrfs-progs, samba, rclone, tailscale)
2. Encrypts the drive with LUKS2
3. Sets up TPM2 auto-unlock (if available)
4. Creates Btrfs filesystem
5. Configures automatic services
6. Creates NAS user and directories

**You will be prompted for:**
- Confirmation to wipe the drive
- LUKS encryption password (choose a strong one!)

### 3. Configure Proton Drive (2 min)

```bash
# Start rclone configuration wizard
sudo rclone config

# Follow these steps:
# n) New remote
# name> proton-nas
# Storage> protondrive (or select number for Proton Drive)
# [Follow authentication prompts]
# q) Quit config
```

### 4. Configure Tailscale (1 min)

```bash
# Authenticate with Tailscale
sudo tailscale up

# Note your Tailscale IP
sudo tailscale ip
```

### 5. Add Your User (1 min)

```bash
# Add your user to NAS group
sudo usermod -aG nas $USER

# Set Samba password
sudo smbpasswd -a $USER

# Enter password (can be different from system password)
```

### 6. Test Everything (2 min)

```bash
# Check status
sudo ./nas-status.sh

# Create test file
echo "NAS is working!" | sudo tee /srv/nas/data/test.txt

# Run manual backup
sudo ./nas-backup.sh --verify

# Access from remote device:
# smb://<your-tailscale-ip>/nas-data
```

---

## What You Get

After setup completes, you'll have:

✅ **Encrypted NAS drive** (LUKS2, auto-unlocks with TPM2)
✅ **File sharing** (Samba over Tailscale)
✅ **Hourly snapshots** (24 hours of history)
✅ **Daily Proton Drive backup** (encrypted cloud backup)
✅ **Automatic operation** (no manual intervention needed)

---

## Common First-Time Issues

### Issue: "TPM2 not available"
**Solution**: Normal on some systems. You'll need to unlock manually on boot:
```bash
sudo cryptsetup open /dev/sdX nas-data
sudo mount /dev/mapper/nas-data /srv/nas
```

### Issue: "Cannot access via Samba"
**Solution**: Check firewall and Tailscale:
```bash
# Test locally first
smbclient //localhost/nas-data -U $USER

# Check Tailscale
sudo tailscale status

# Restart Samba
sudo systemctl restart smb nmb
```

### Issue: "Proton Drive sync failed"
**Solution**: Verify rclone config:
```bash
# Test connection
sudo rclone lsd proton-nas:

# If fails, reconfigure
sudo rclone config
```

---

## Daily Usage

### Access Files Locally

```bash
# As root or member of 'nas' group
cd /srv/nas/data
```

### Access Files Remotely (Tailscale)

**Linux/Mac:**
```bash
# One-time mount
sudo mkdir -p /mnt/nas
sudo mount -t cifs //<tailscale-ip>/nas-data /mnt/nas -o username=$USER
```

**Windows:**
- Open File Explorer
- Type: `\\<tailscale-ip>\nas-data`
- Enter credentials

**Android (via app):**
- Install "CX File Explorer" or similar SMB client
- Add network location
- Use Tailscale IP

### Check System Health

```bash
# Quick status check
sudo ./nas-status.sh

# View logs
sudo tail -f /var/log/nas-proton-sync.log
```

### Manual Backup

```bash
# Backup now with verification
sudo ./nas-backup.sh --verify --snapshot
```

---

## Quick Reference Commands

| Task | Command |
|------|---------|
| Check status | `sudo ./nas-status.sh` |
| Manual backup | `sudo ./nas-backup.sh` |
| View Proton log | `sudo tail /var/log/nas-proton-sync.log` |
| List snapshots | `sudo ls /srv/nas/.snapshots/` |
| Tailscale IP | `sudo tailscale ip` |
| Restart Samba | `sudo systemctl restart smb` |
| Check disk usage | `df -h /srv/nas` |
| Btrfs health | `sudo btrfs device stats /srv/nas` |

---

## Automatic Operations

These run automatically, no action needed:

| What | When | Why |
|------|------|-----|
| Btrfs snapshot | Every hour | Point-in-time recovery |
| Proton Drive sync | Every 24 hours | Off-site backup |
| Snapshot cleanup | After each snapshot | Maintain 24-hour window |

---

## Security Tips

1. **Save your LUKS password!** Write it down and store securely offline.
2. **Test recovery** before you need it (restore a file from snapshot).
3. **Monitor logs** weekly for any issues.
4. **Update regularly**: `sudo yay -Syu`
5. **Only share via Tailscale** (don't expose Samba to internet).

---

## Getting Help

**Check status first:**
```bash
sudo ./nas-status.sh
```

**View service logs:**
```bash
# Samba
sudo journalctl -u smb -n 50

# Proton sync
sudo journalctl -u nas-proton-sync.service -n 50

# Snapshots
sudo journalctl -u nas-snapshot.service -n 50
```

**Full documentation:**
- Detailed guide: `README.md`
- Architecture: `ARCHITECTURE.md`
- Troubleshooting: `README.md#troubleshooting`

---

## Next Steps

Once comfortable with basic operation:

1. **Customize backup schedule** (edit timers in `/etc/systemd/system/`)
2. **Add more Samba shares** (edit `/etc/samba/smb.conf`)
3. **Enable auto-scrub** (see `ARCHITECTURE.md`)
4. **Set up email notifications** (see `README.md#advanced-configuration`)
5. **Test disaster recovery** (practice restoring from Proton Drive)

---

## Removal

If you need to remove the NAS:

```bash
# Keep data (can re-access later)
sudo ./nas-remove.sh --keep-data

# Complete removal (destroys everything)
sudo ./nas-remove.sh
```

---

**You're all set! Your NAS is now running autonomously.**

For detailed documentation, see `README.md`.
