#!/usr/bin/env python3
import subprocess
import sys
import getpass
from pathlib import Path

def run(cmd, check=True):
    """Run shell command"""
    print(f"→ {cmd}")
    return subprocess.run(cmd, shell=True, check=check, 
                         capture_output=True, text=True)

def create_nas_user():
    username = input("NAS username [nas]: ") or "nas"
    password = getpass.getpass("NAS password: ")
    
    # Create user
    run(f"useradd -m -d /mnt/nas/home/{username} -s /bin/zsh {username}")
    
    # Set password (insecure way shown - better: use chpasswd)
    proc = subprocess.Popen(["passwd", username], 
                           stdin=subprocess.PIPE)
    proc.communicate(f"{password}\n{password}\n".encode())

def setup_encrypted_drive():
    # List drives
    run("lsblk")
    drive = input("Drive to use (e.g., sda): ")
    
    if not input(f"⚠️  DESTROY /dev/{drive}? [yes]: ") == "yes":
        sys.exit("Aborted")
    
    luks_pass = getpass.getpass("LUKS password: ")
    
    # Format
    proc = subprocess.Popen(
        f"cryptsetup luksFormat /dev/{drive}",
        shell=True, stdin=subprocess.PIPE
    )
    proc.communicate(f"YES\n{luks_pass}\n{luks_pass}\n".encode())
    
    # Open
    proc = subprocess.Popen(
        f"cryptsetup open /dev/{drive} nas_storage",
        shell=True, stdin=subprocess.PIPE
    )
    proc.communicate(f"{luks_pass}\n".encode())
    
    # Format filesystem
    run("mkfs.ext4 /dev/mapper/nas_storage")
    
    # Mount
    run("mkdir -p /mnt/nas")
    run("mount /dev/mapper/nas_storage /mnt/nas")

def setup_syncthing():
    run("systemctl enable --now syncthing@nas")
    print("✓ Syncthing enabled")

def setup_rclone():
    print("\n⚠️  Run manually: sudo -u nas rclone config")
    print("(Interactive auth required)")

def create_backup_script():
    script = '''#!/bin/bash
export RESTIC_REPOSITORY="rclone:remote:backup"
export RESTIC_PASSWORD_FILE="/mnt/nas/home/nas/.restic_password"

rclone sync /mnt/nas/sync remote:files
restic backup /mnt/nas/sync
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
'''
    Path("/usr/local/bin/nas-backup.sh").write_text(script)
    run("chmod +x /usr/local/bin/nas-backup.sh")
    run("chown nas:nas /usr/local/bin/nas-backup.sh")

def setup_systemd():
    service = '''[Unit]
Description=NAS Backup
After=network-online.target

[Service]
Type=oneshot
User=nas
ExecStart=/usr/local/bin/nas-backup.sh
'''
    
    timer = '''[Unit]
Description=Daily NAS backup

[Timer]
OnCalendar=daily
OnCalendar=03:00
Persistent=true

[Install]
WantedBy=timers.target
'''
    
    Path("/etc/systemd/system/nas-backup.service").write_text(service)
    Path("/etc/systemd/system/nas-backup.timer").write_text(timer)
    
    run("systemctl daemon-reload")
    run("systemctl enable --now nas-backup.timer")

if __name__ == "__main__":
    if os.geteuid() != 0:
        sys.exit("Need root")
    
    create_nas_user()
    setup_encrypted_drive()
    setup_syncthing()
    create_backup_script()
    setup_systemd()
    
    print("\n✓ Done! Manually run:")
    print("  sudo -u nas rclone config")
    print("  sudo -u nas restic init --repo rclone:remote:backup")