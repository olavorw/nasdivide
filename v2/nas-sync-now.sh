#!/bin/bash

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

echo "Starting manual sync..."
systemctl start nas-proton-sync.service
systemctl status nas-proton-sync.service --no-pager
