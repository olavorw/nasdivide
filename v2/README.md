# NASDIVIDE V2

## Post-Setup Configuration

After running setup, configure:

**1. Rclone (Proton Drive):**

```bash
sudo -u nas-user rclone config --config /etc/nas/rclone.conf
# Follow prompts for Proton Drive setup
```

**2. Tailscale:**

```bash
sudo tailscale up
```

**3. Syncthing:**

- Access at `http://localhost:8384`
- Add folders: `/srv/nas/shared`
- Add remote devices via Tailscale IPs

**4. Test:**

```bash
sudo systemctl start nas-proton-sync.service
sudo ./nas-status.sh
```

## Security Features Implemented

- ✅ LUKS2 with AES-XTS-Plain64 (512-bit keys)
- ✅ Argon2id key derivation
- ✅ Dedicated unprivileged user
- ✅ Auto-unlock with protected keyfile
- ✅ BTRFS snapshots before every sync
- ✅ Encrypted at-rest and in-transit (Tailscale)
- ✅ No manual intervention required
- ✅ Comprehensive health monitoring
- ✅ Privacy-focused (Proton Drive, Tailscale)

## Data Loss Prevention

- Pre-sync snapshots (retained 2 days)
- Rclone retry mechanisms
- Health checks before operations
- BTRFS checksumming
- Versioned syncing
- Transaction logging
