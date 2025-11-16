#!/bin/bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_status() {
  local service=$1
  if systemctl is-active --quiet "$service"; then
    echo -e "${GREEN}●${NC} $service: active"
  else
    echo -e "${RED}●${NC} $service: inactive"
  fi
}

echo "=== NAS Status ==="
echo ""

echo "Services:"
print_status "nas-mount.service"
print_status "nas-proton-sync.timer"
print_status "nas-snapshot.timer"
print_status "nas-health.timer"
print_status "syncthing@nas-user.service"
print_status "tailscaled.service"

echo ""
echo "Mount Status:"
if mountpoint -q /srv/nas; then
  echo -e "${GREEN}✓${NC} /srv/nas mounted"
  df -h /srv/nas | tail -n 1
else
  echo -e "${RED}✗${NC} /srv/nas not mounted"
fi

echo ""
echo "LUKS Status:"
if cryptsetup status nas-crypt &>/dev/null; then
  echo -e "${GREEN}✓${NC} nas-crypt unlocked"
else
  echo -e "${RED}✗${NC} nas-crypt locked"
fi

echo ""
echo "Last Sync Status:"
if [[ -f /var/log/nas/last-sync-status ]]; then
  STATUS=$(cat /var/log/nas/last-sync-status)
  if [[ "$STATUS" == "SUCCESS" ]]; then
    echo -e "${GREEN}✓${NC} Last sync: SUCCESS"
  else
    echo -e "${RED}✗${NC} Last sync: FAILED"
  fi

  if [[ -f /var/log/nas/last-sync-status.timestamp ]]; then
    echo "   Time: $(date -r /var/log/nas/last-sync-status.timestamp)"
  fi
else
  echo -e "${YELLOW}?${NC} No sync data available"
fi

echo ""
echo "Recent Snapshots:"
if mount -o subvol=/ /dev/mapper/nas-crypt /mnt/nas-root 2>/dev/null; then
  ls -lt /mnt/nas-root/snapshots | head -n 6 | tail -n 5
  umount /mnt/nas-root 2>/dev/null
else
  echo "Unable to list snapshots"
fi

echo ""
echo "Logs:"
echo "  Proton sync: journalctl -u nas-proton-sync.service"
echo "  Health: tail /var/log/nas/health.log"
echo "  All NAS: journalctl -u 'nas-*'"
