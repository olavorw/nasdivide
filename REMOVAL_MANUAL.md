# NAS Setup Removal Guide

## ⚠️ WARNING

**This will permanently delete:**
- All data in `/mnt/nas`
- NAS user and configurations
- Syncthing sync data
- Local backup snapshots

**This will NOT delete:**
- Data in Proton Drive (must delete manually)
- Your personal user data
- Your main Syncthing instance

---

## Step 1: Backup Important Data

### Export What You Want to Keep
```bash
# Copy important files elsewhere
sudo cp -r /mnt/nas/sync /path/to/safe/location

# Export Syncthing config (if needed later)
sudo -u nas syncthing --export-config > ~/nas-syncthing-backup.xml
```

---

## Step 2: Stop Services

```bash
# Stop and disable timer
sudo systemctl stop nas-backup.timer
sudo systemctl disable nas-backup.timer

# Stop Syncthing
sudo systemctl stop syncthing@nas
sudo systemctl disable syncthing@nas

# Verify stopped
sudo systemctl status syncthing@nas
sudo systemctl status nas-backup.timer
```

---

## Step 3: Remove Proton Drive Data (Optional)

### Via rclone
```bash
# List what's there
sudo -u nas rclone ls remote:

# Delete backup repository
sudo -u nas rclone purge remote:backup

# Delete mirrored files
sudo -u nas rclone purge remote:files

# Or delete everything
sudo -u nas rclone delete remote: --rmdirs
```

### Via Web Browser
- Go to https://drive.proton.me
- Manually delete `backup/` and `files/` folders
- Empty trash

---

## Step 4: Remove Systemd Files

```bash
sudo systemctl stop nas-backup.service
sudo rm /etc/systemd/system/nas-backup.service
sudo rm /etc/systemd/system/nas-backup.timer
sudo rm /usr/local/bin/nas-backup.sh
sudo systemctl daemon-reload
```

---

## Step 5: Remove NAS User

```bash
# Kill any running processes
sudo pkill -u nas

# Delete user and home directory
sudo userdel -r nas

# Verify removed
id nas  # Should show "no such user"
```

---

## Step 6: Unmount and Remove Drive

### Unmount
```bash
# Check what's using it
sudo lsof /mnt/nas

# Unmount
sudo umount /mnt/nas

# Close encrypted volume
sudo cryptsetup close nas_storage
```

### Remove Auto-mount
```bash
# Edit /etc/fstab - remove this line:
sudo nano /etc/fstab
# Delete: /dev/mapper/nas_storage /mnt/nas ext4 defaults 0 2

# Edit /etc/crypttab - remove this line:
sudo nano /etc/crypttab
# Delete: nas_storage UUID=... none luks
```

### Remove Mount Point
```bash
sudo rmdir /mnt/nas
```

---

## Step 7: Wipe Drive (Optional)

### Securely Erase
```bash
# Find your drive
lsblk

# Wipe with random data (SLOW - can take hours)
sudo dd if=/dev/urandom of=/dev/sdX bs=1M status=progress

# Or quick zero-fill
sudo dd if=/dev/zero of=/dev/sdX bs=1M status=progress

# Or just remove LUKS header (makes data unrecoverable)
sudo cryptsetup erase /dev/sdX
```

### Re-partition for Other Use
```bash
# Use the drive for something else
sudo fdisk /dev/sdX
# Or GUI: gparted
```

---

## Step 8: Remove Configurations

### rclone Config
```bash
# Remove as your user (if you added it)
rclone config delete remote

# NAS user config already deleted with user
```

### Syncthing Data
```bash
# Already removed with user home directory
# But if you want to clean your main instance:
# Remove NAS device from your Syncthing UI at localhost:8384
```

---

## Step 9: Remove Packages (Optional)

### If You Don't Use Them Elsewhere
```bash
# Remove Syncthing (only if not using in main user)
# Check first: systemctl --user status syncthing
# If safe:
sudo pacman -Rns syncthing

# Remove rclone
sudo pacman -Rns rclone

# Remove restic
sudo pacman -Rns restic

# Remove Tailscale (if installed and not needed)
sudo pacman -Rns tailscale
```

---

## Step 10: Clean UFW Rules (Optional)

```bash
# List rules
sudo ufw status numbered

# Delete NAS-related rules
sudo ufw delete [rule-number]

# Or delete by comment
sudo ufw delete allow 42697/tcp
sudo ufw delete allow 33727/tcp
sudo ufw delete allow 33727/udp
```

---

## Verification Checklist

```bash
# User removed
id nas  # Should fail

# Mount removed
df -h | grep nas  # Should show nothing
ls /mnt/nas  # Should not exist

# Services removed
systemctl list-units | grep nas  # Should show nothing

# Timers removed
systemctl list-timers | grep nas  # Should show nothing

# Processes removed
ps aux | grep nas  # Should only show grep itself
```

---

## Partial Removal Options

### Keep Drive, Remove User
```bash
# Stop services
sudo systemctl stop syncthing@nas nas-backup.timer
sudo systemctl disable syncthing@nas nas-backup.timer

# Just remove user
sudo userdel nas

# Keep drive mounted, use with your main user
sudo chown -R yourusername:yourusername /mnt/nas
```

### Keep Everything, Just Disable
```bash
# Stop but don't delete
sudo systemctl stop syncthing@nas
sudo systemctl stop nas-backup.timer
sudo systemctl disable syncthing@nas
sudo systemctl disable nas-backup.timer

# Re-enable later if needed
sudo systemctl enable --now syncthing@nas
sudo systemctl enable --now nas-backup.timer
```

### Remove Only Backups, Keep Syncthing
```bash
# Stop backup timer
sudo systemctl stop nas-backup.timer
sudo systemctl disable nas-backup.timer
sudo rm /etc/systemd/system/nas-backup.{service,timer}
sudo rm /usr/local/bin/nas-backup.sh

# Keep Syncthing running
# Keep drive and user
```

---

## Repurpose Drive

### Use for Personal Storage
```bash
# Keep encrypted, change owner
sudo chown -R yourusername:yourusername /mnt/nas

# Or decrypt and reformat
sudo umount /mnt/nas
sudo cryptsetup close nas_storage
sudo mkfs.ext4 /dev/sdX  # Removes encryption
```

### Sell/Give Away Drive
```bash
# Secure wipe first
sudo cryptsetup erase /dev/sdX  # Quick, destroys keys
# Or:
sudo shred -v -n 1 /dev/sdX  # Slower, overwrites everything
```

---

## Emergency Quick Removal

```bash
#!/bin/bash
# emergency-remove.sh - Nuclear option

sudo systemctl stop syncthing@nas nas-backup.timer
sudo systemctl disable syncthing@nas nas-backup.timer
sudo pkill -u nas
sudo userdel -r nas
sudo umount /mnt/nas
sudo cryptsetup close nas_storage
sudo rm /etc/systemd/system/nas-backup.{service,timer}
sudo rm /usr/local/bin/nas-backup.sh
sudo rmdir /mnt/nas
sudo systemctl daemon-reload

echo "NAS setup removed. Drive still contains data."
echo "Manually edit /etc/fstab and /etc/crypttab"
echo "Wipe drive with: sudo dd if=/dev/zero of=/dev/sdX"
```

---

## Recovery After Accidental Removal

### If Data Still on Drive
```bash
# Remount drive
sudo cryptsetup open /dev/sdX nas_storage
sudo mount /dev/mapper/nas_storage /mnt/nas

# Copy data out
cp -r /mnt/nas/sync ~/recovered-data/
```

### If You Have Proton Drive Backups
```bash
# Restore from direct files
rclone copy remote:files ~/recovered-data/

# Or restore from restic snapshot
restic -r rclone:remote:backup restore latest --target ~/recovered-data/
```

---

## Notes

- **Drive data persists** until overwritten
- **Proton Drive data** stays until manually deleted
- **Syncthing peers** will show device as disconnected
- **Backup snapshots** in Proton count toward storage quota
- Removing services doesn't free up Proton storage automatically

**When in doubt, backup first!**