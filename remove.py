#!/usr/bin/env python3
import subprocess
import sys
import os
from pathlib import Path

def run(cmd, check=False):
    """Run shell command"""
    print(f"→ {cmd}")
    result = subprocess.run(cmd, shell=True, check=check, 
                           capture_output=True, text=True)
    if result.stdout:
        print(result.stdout)
    if result.stderr and check:
        print(f"ERROR: {result.stderr}", file=sys.stderr)
    return result

def confirm(message):
    """Get user confirmation"""
    response = input(f"{message} [yes/no]: ")
    return response.lower() == "yes"

def stop_services():
    """Stop and disable NAS services"""
    print("\n=== Stopping Services ===")
    run("systemctl stop nas-backup.timer")
    run("systemctl stop nas-backup.service")
    run("systemctl disable nas-backup.timer")
    run("systemctl stop syncthing@nas")
    run("systemctl disable syncthing@nas")
    print("✓ Services stopped")

def remove_systemd_files():
    """Remove systemd unit files"""
    print("\n=== Removing Systemd Files ===")
    files = [
        "/etc/systemd/system/nas-backup.service",
        "/etc/systemd/system/nas-backup.timer",
        "/usr/local/bin/nas-backup.sh"
    ]
    
    for file in files:
        if Path(file).exists():
            Path(file).unlink()
            print(f"✓ Removed {file}")
    
    run("systemctl daemon-reload")

def remove_nas_user():
    """Remove NAS user and data"""
    print("\n=== Removing NAS User ===")
    username = input("NAS username to remove [nas]: ") or "nas"
    
    # Kill processes
    run(f"pkill -u {username}")
    
    # Delete user and home
    result = run(f"userdel -r {username}")
    if result.returncode == 0:
        print(f"✓ Removed user '{username}'")
    else:
        print(f"⚠️  User '{username}' may not exist or already removed")

def unmount_drive():
    """Unmount and close encrypted drive"""
    print("\n=== Unmounting Drive ===")
    
    # Check what's using it
    run("lsof /mnt/nas")
    
    # Unmount
    result = run("umount /mnt/nas")
    if result.returncode == 0:
        print("✓ Unmounted /mnt/nas")
    else:
        print("⚠️  /mnt/nas may not be mounted")
    
    # Close LUKS
    result = run("cryptsetup close nas_storage")
    if result.returncode == 0:
        print("✓ Closed encrypted volume")
    else:
        print("⚠️  nas_storage may not be open")

def remove_mount_point():
    """Remove mount point directory"""
    print("\n=== Removing Mount Point ===")
    if Path("/mnt/nas").exists():
        Path("/mnt/nas").rmdir()
        print("✓ Removed /mnt/nas")

def wipe_drive():
    """Optionally wipe the drive"""
    print("\n=== Drive Wiping ===")
    if not confirm("Do you want to wipe the drive?"):
        print("Skipping drive wipe")
        return
    
    run("lsblk")
    drive = input("Drive to wipe (e.g., sda) (do not include '/dev/'!!!): ")
    
    if not confirm(f"⚠️⚠️⚠️  PERMANENTLY ERASE ALL DATA on /dev/{drive}?"):
        print("Aborted wipe")
        return
    
    print("\nWipe options:")
    print("1. Quick (erase LUKS header only - fast)")
    print("2. Secure (overwrite with zeros - slow)")
    print("3. Cancel")
    
    choice = input("Choose [1/2/3]: ")
    
    if choice == "1":
        run(f"cryptsetup erase /dev/{drive}", check=True)
        print("✓ LUKS header erased (data unrecoverable)")
    elif choice == "2":
        if confirm("This will take HOURS. Continue?"):
            run(f"dd if=/dev/zero of=/dev/{drive} bs=1M status=progress", check=True)
            print("✓ Drive securely wiped")
    else:
        print("Wipe cancelled")

def remove_fstab_entries():
    """Remind to edit fstab and crypttab"""
    print("\n=== Manual Steps Required ===")
    print("⚠️  Edit these files manually:")
    print("  sudo nano /etc/fstab")
    print("    Remove line: /dev/mapper/nas_storage /mnt/nas ...")
    print()
    print("  sudo nano /etc/crypttab")
    print("    Remove line: nas_storage UUID=... ...")

def remove_proton_data():
    """Remind about Proton Drive cleanup"""
    print("\n=== Proton Drive Cleanup ===")
    if confirm("Do you want instructions to delete Proton Drive data?"):
        print("\nManual cleanup required:")
        print("  sudo -u nas rclone purge remote:backup")
        print("  sudo -u nas rclone purge remote:files")
        print()
        print("Or via web browser:")
        print("  1. Go to https://drive.proton.me")
        print("  2. Delete 'backup' and 'files' folders")
        print("  3. Empty trash")

def verify_removal():
    """Verify everything is removed"""
    print("\n=== Verification ===")
    
    checks = [
        ("User removed", "id nas"),
        ("Mount removed", "df -h | grep nas"),
        ("Services removed", "systemctl list-units | grep nas"),
        ("Timers removed", "systemctl list-timers | grep nas"),
    ]
    
    for desc, cmd in checks:
        result = run(cmd)
        if result.returncode != 0 or not result.stdout.strip():
            print(f"✓ {desc}")
        else:
            print(f"⚠️  {desc} - may need manual cleanup")

def main():
    """Main removal process"""
    if os.geteuid() != 0:
        sys.exit("❌ This script must be run as root (use sudo)")
    
    print("=" * 60)
    print("NAS SETUP REMOVAL SCRIPT")
    print("=" * 60)
    print("\n⚠️  WARNING: This will remove:")
    print("  - NAS user and all data in /mnt/nas")
    print("  - Syncthing@nas configuration")
    print("  - Backup scripts and timers")
    print("  - Unmount encrypted drive")
    print()
    print("This will NOT remove:")
    print("  - Data in Proton Drive (must delete manually)")
    print("  - Your personal user data")
    print("  - Installed packages (rclone, restic, syncthing)")
    print()
    
    if not confirm("Continue with removal?"):
        sys.exit("Aborted")
    
    # Backup reminder
    if not confirm("Have you backed up any important data from /mnt/nas?"):
        print("\n⚠️  Backup your data first!")
        print("Example: sudo cp -r /mnt/nas/sync /backup/location/")
        if not confirm("Proceed anyway?"):
            sys.exit("Aborted")
    
    # Execute removal steps
    try:
        stop_services()
        remove_systemd_files()
        remove_nas_user()
        unmount_drive()
        remove_mount_point()
        wipe_drive()
        remove_fstab_entries()
        remove_proton_data()
        verify_removal()
        
        print("\n" + "=" * 60)
        print("✓ NAS SETUP REMOVAL COMPLETE")
        print("=" * 60)
        print("\nRemember to:")
        print("  1. Edit /etc/fstab and /etc/crypttab")
        print("  2. Clean up Proton Drive manually")
        print("  3. Remove packages if not needed elsewhere:")
        print("     sudo pacman -Rns syncthing rclone restic")
        
    except Exception as e:
        print(f"\n❌ Error during removal: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()