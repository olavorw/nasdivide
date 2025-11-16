# NAS Architecture & Security Design

## Table of Contents
1. [System Architecture](#system-architecture)
2. [Security Model](#security-model)
3. [Data Flow](#data-flow)
4. [Component Details](#component-details)
5. [Threat Model](#threat-model)
6. [Recovery Procedures](#recovery-procedures)

---

## System Architecture

### Layer Model

```
┌─────────────────────────────────────────────────────────────┐
│                      User Space Layer                        │
│  ┌────────────┐  ┌────────────┐  ┌──────────┐               │
│  │   Samba    │  │  Tailscale │  │  Rclone  │               │
│  │ (sharing)  │  │ (network)  │  │ (backup) │               │
│  └──────┬─────┘  └──────┬─────┘  └─────┬────┘               │
├─────────┼────────────────┼──────────────┼────────────────────┤
│         │           Application Layer   │                    │
│         │                │               │                    │
│    ┌────▼────────────────▼───────────────▼─────┐             │
│    │        /srv/nas (Btrfs Mount)              │             │
│    │  ├─ data/        (primary storage)         │             │
│    │  ├─ shares/      (additional shares)       │             │
│    │  └─ .snapshots/  (Btrfs snapshots)         │             │
│    └────────────────┬───────────────────────────┘             │
├─────────────────────┼─────────────────────────────────────────┤
│              Filesystem Layer                                 │
│    ┌────────────────▼───────────────────────────┐             │
│    │  Btrfs Filesystem                          │             │
│    │  - COW (Copy-on-Write)                     │             │
│    │  - Checksums (SHA-256)                     │             │
│    │  - Compression (Zstd:3)                    │             │
│    │  - Snapshots (Incremental)                 │             │
│    └────────────────┬───────────────────────────┘             │
├─────────────────────┼─────────────────────────────────────────┤
│              Encryption Layer                                 │
│    ┌────────────────▼───────────────────────────┐             │
│    │  LUKS2 Container (/dev/mapper/nas-data)    │             │
│    │  - Cipher: AES-XTS-Plain64                 │             │
│    │  - Key Size: 512-bit                       │             │
│    │  - PBKDF: Argon2id                         │             │
│    │  - Auto-unlock: TPM2 (PCR 0+7)             │             │
│    └────────────────┬───────────────────────────┘             │
├─────────────────────┼─────────────────────────────────────────┤
│              Hardware Layer                                   │
│    ┌────────────────▼───────────────────────────┐             │
│    │  Physical Drive (/dev/sdX)                 │             │
│    │  - Second drive dedicated to NAS           │             │
│    └────────────────────────────────────────────┘             │
└─────────────────────────────────────────────────────────────┘
```

### Component Interaction

```
┌──────────────┐
│ User Request │
└──────┬───────┘
       │
       ▼
┌──────────────────────────────────────┐
│     Access Method                     │
│  ┌──────────┐      ┌──────────────┐  │
│  │  Local   │      │   Remote     │  │
│  │  (Direct)│      │ (Tailscale)  │  │
│  └────┬─────┘      └──────┬───────┘  │
└───────┼────────────────────┼──────────┘
        │                    │
        ▼                    ▼
    ┌───────────────────────────┐
    │      Samba (SMB3)         │
    │   - Encrypted Transport    │
    │   - User Authentication    │
    └─────────┬─────────────────┘
              │
              ▼
    ┌─────────────────────┐
    │  Permission Check    │
    │  - User in 'nas'?    │
    │  - Valid password?   │
    └─────────┬───────────┘
              │
              ▼
    ┌─────────────────────┐
    │   Btrfs Layer        │
    │  - Checksum verify   │
    │  - COW operation     │
    └─────────┬───────────┘
              │
              ▼
    ┌─────────────────────┐
    │   Data Storage       │
    │  /srv/nas/data       │
    └─────────────────────┘
```

---

## Security Model

### Defense in Depth

The system implements multiple security layers:

#### 1. **Physical Security**
- Full disk encryption (LUKS2)
- TPM2-based auto-unlock (secure boot chain)
- Separate physical drive (isolation)

#### 2. **Network Security**
- Tailscale mesh network (WireGuard)
- No port forwarding required
- End-to-end encryption
- SMB3 mandatory encryption

#### 3. **Authentication & Authorization**
- Dedicated system user (`nas`)
- PAM authentication for Samba
- Group-based permissions
- No remote root access

#### 4. **Data Security**
- Btrfs checksums (data integrity)
- Atomic COW operations
- Encrypted backups (Proton Drive)
- Regular snapshots (point-in-time recovery)

#### 5. **Service Isolation**
- Minimal privileges (systemd hardening)
- Private /tmp
- NoNewPrivileges flag
- Restricted capabilities

### Encryption Details

#### LUKS2 Configuration
```
Algorithm:     AES-XTS-Plain64
Key Size:      512 bits
Hash:          SHA-512
PBKDF:         Argon2id
Memory:        1 GiB (1048576 KiB)
Parallel:      4 threads
Iterations:    4 (forced)
Key Slots:     2 (password + TPM2)
```

#### TPM2 Auto-Unlock
- **PCR 0**: BIOS/UEFI firmware
- **PCR 7**: Secure Boot state

The drive auto-unlocks **only if**:
1. Secure Boot is enabled
2. Boot chain is unmodified
3. TPM2 has not been reset
4. PCR values match enrollment

This prevents:
- Booting from live USB to access data
- BIOS/bootloader tampering
- Physical drive theft (without system)

---

## Data Flow

### Write Operation

```
User Write → Samba → Permission Check → Btrfs
                                          ↓
                                    Checksum Data
                                          ↓
                                    COW Allocation
                                          ↓
                                    Write to LUKS
                                          ↓
                                    Encrypt Block
                                          ↓
                                    Write to Disk
```

### Backup Flow

```
Timer Trigger (daily) → nas-proton-sync.service
                              ↓
                        Check rclone config
                              ↓
                        Read /srv/nas/data
                              ↓
                        Calculate checksums
                              ↓
                        Compare with remote
                              ↓
                        Upload changes (encrypted)
                              ↓
                        Verify integrity
                              ↓
                        Log results
```

### Snapshot Flow

```
Timer Trigger (hourly) → nas-snapshot.service
                               ↓
                         Btrfs snapshot (COW)
                               ↓
                         Create read-only subvolume
                               ↓
                         Store in .snapshots/
                               ↓
                         Cleanup old snapshots (>24)
                               ↓
                         Log completion
```

---

## Component Details

### 1. LUKS2 Encryption

**Purpose**: Full-disk encryption for data at rest

**Key Management**:
- Slot 0: User password (fallback)
- Slot 1: TPM2 token (auto-unlock)

**Security Properties**:
- **Confidentiality**: AES-256 (XTS mode)
- **Authentication**: HMAC-SHA-512
- **Key Derivation**: Argon2id (memory-hard)

**Attack Resistance**:
- ✓ Cold boot attacks (encryption at rest)
- ✓ Brute force (Argon2id)
- ✓ Physical theft (no key without TPM)
- ✗ Evil maid (if Secure Boot disabled)

### 2. Btrfs Filesystem

**Purpose**: Data integrity and snapshot capability

**Features Used**:
- **Checksums**: SHA-256 on all data/metadata
- **COW**: Atomic operations, no partial writes
- **Compression**: Zstd (3:1 ratio typically)
- **Snapshots**: Instant, space-efficient

**Data Integrity**:
- Checksums detect silent corruption
- Redundant metadata
- Self-healing (if configured with RAID)

**Snapshot Strategy**:
```
Hourly:  24 snapshots (1 day coverage)
Daily:   7 snapshots  (1 week coverage)
Weekly:  4 snapshots  (1 month coverage)
```

### 3. Samba (SMB3)

**Purpose**: File sharing over network

**Security Configuration**:
- **Protocol**: SMB 3.1.1 minimum
- **Encryption**: Mandatory (AES-128-CCM)
- **Authentication**: PAM (system users)
- **Authorization**: Group-based ACLs

**Attack Mitigations**:
- ✓ Man-in-the-middle (encryption)
- ✓ Password sniffing (encrypted auth)
- ✓ Unauthorized access (ACLs)
- ✓ Network exposure (Tailscale only)

### 4. Tailscale

**Purpose**: Secure remote access without port forwarding

**How It Works**:
1. WireGuard-based mesh network
2. Peer-to-peer connections
3. NAT traversal
4. Encrypted tunnels

**Benefits**:
- No firewall configuration needed
- No exposed ports
- Encrypted by default
- Easy device management

### 5. Rclone (Proton Drive)

**Purpose**: Encrypted cloud backup (disaster recovery)

**Configuration**:
- **Remote**: Proton Drive
- **Encryption**: At-rest (Proton) + in-transit (TLS)
- **Sync Mode**: Incremental (only changes)
- **Verification**: Checksum-based

**Backup Strategy**:
- Daily sync to cloud
- Only `/srv/nas/data` (not snapshots)
- Incremental (minimal bandwidth)
- Encrypted before upload

---

## Threat Model

### Threats Mitigated ✓

| Threat | Mitigation |
|--------|------------|
| Physical drive theft | LUKS2 encryption + TPM2 binding |
| Network eavesdropping | SMB3 encryption + Tailscale |
| Unauthorized local access | User/group permissions + Samba auth |
| Data corruption | Btrfs checksums + snapshots |
| Accidental deletion | Hourly snapshots (24h retention) |
| Ransomware | Snapshots + Proton Drive backup |
| Drive failure | Proton Drive backup (off-site) |
| Boot tampering | TPM2 PCR checks |

### Threats NOT Mitigated ✗

| Threat | Why Not Mitigated | Recommendation |
|--------|-------------------|----------------|
| Memory attacks (running system) | LUKS decrypted when mounted | Use encrypted swap |
| Malicious kernel modules | No kernel hardening | Enable kernel lockdown mode |
| Advanced persistent threats | Limited monitoring | Add intrusion detection |
| Social engineering | Human factor | User training |
| Supply chain attacks | Hardware trust | Use secure hardware |

### Attack Scenarios

#### Scenario 1: Physical Theft of NAS Drive
1. Attacker steals the NAS drive
2. **Result**: Data remains encrypted
3. **Attacker needs**: Original system + TPM2 OR password

**Status**: ✓ Mitigated

#### Scenario 2: Remote Network Attack
1. Attacker scans network for SMB
2. **Result**: No exposed ports (Tailscale only)
3. **Even if found**: SMB3 encryption + authentication required

**Status**: ✓ Mitigated

#### Scenario 3: Compromised System (Running)
1. Attacker gains root on personal system
2. **Result**: Can access mounted NAS data
3. **Limitation**: Cannot disable TPM2 or extract keys without detection

**Status**: ⚠️ Partially mitigated (need IDS/SELinux)

#### Scenario 4: Evil Maid Attack
1. Attacker physical access to system
2. Modifies bootloader or BIOS
3. **Result**: TPM2 PCRs change, auto-unlock fails
4. **Fallback**: Password required

**Status**: ✓ Detected (requires password)

---

## Recovery Procedures

### Scenario: TPM2 Failure

```bash
# Symptoms: Drive won't auto-unlock on boot

# 1. Check TPM2 status
dmesg | grep -i tpm
ls /sys/class/tpm

# 2. Manually unlock with password
sudo cryptsetup open /dev/sdX nas-data
# Enter your LUKS password

# 3. Mount drive
sudo mount /dev/mapper/nas-data /srv/nas

# 4. Re-enroll TPM2
sudo systemd-cryptenroll --wipe-slot=tpm2 /dev/sdX
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/sdX

# 5. Reboot and test
```

### Scenario: Corrupted Filesystem

```bash
# Symptoms: I/O errors, mount failures

# 1. Check Btrfs errors
sudo btrfs device stats /dev/mapper/nas-data

# 2. Run filesystem check (unmount first!)
sudo umount /srv/nas
sudo btrfs check /dev/mapper/nas-data

# 3. If errors found, run repair
sudo btrfs check --repair /dev/mapper/nas-data

# 4. Remount
sudo mount /dev/mapper/nas-data /srv/nas

# 5. Verify data
sudo btrfs scrub start /srv/nas
```

### Scenario: Complete Drive Failure

```bash
# Data recovery from Proton Drive

# 1. Set up new NAS drive
sudo ./nas-setup.sh /dev/sdX

# 2. Configure rclone (use existing config)
sudo rclone config

# 3. Restore data
sudo rclone sync proton-nas:NAS-Backup /srv/nas/data --progress

# 4. Verify integrity
sudo rclone check proton-nas:NAS-Backup /srv/nas/data

# 5. Resume normal operations
sudo systemctl start nas-proton-sync.timer
```

### Scenario: Accidental Deletion

```bash
# Recover from snapshot (within 24 hours)

# 1. List snapshots
sudo ls -lh /srv/nas/.snapshots/

# 2. Browse snapshot for file
sudo ls /srv/nas/.snapshots/data-20250115-120000/path/to/file

# 3. Restore file
sudo cp /srv/nas/.snapshots/data-20250115-120000/path/to/file /srv/nas/data/path/to/

# 4. Fix permissions
sudo chown nas:nas /srv/nas/data/path/to/file
```

### Scenario: Ransomware Attack

```bash
# If personal system compromised

# 1. Immediately shutdown
sudo poweroff

# 2. Boot from live USB

# 3. Do NOT auto-mount NAS

# 4. Analyze personal system for malware

# 5. If NAS infected:
#    a) From snapshot (if recent)
#    b) From Proton Drive (if older)

# 6. Clean restore process:
sudo cryptsetup open /dev/sdX nas-data
sudo mount /dev/mapper/nas-data /mnt
sudo btrfs subvolume snapshot /mnt/.snapshots/data-LATEST /mnt/data-clean
# Scan data-clean for malware
# If clean, use it; otherwise restore from Proton
```

---

## Best Practices

### Daily Operations
- ✓ Check `nas-status.sh` weekly
- ✓ Monitor logs: `/var/log/nas-proton-sync.log`
- ✓ Verify Tailscale connection
- ✓ Test file access from remote device

### Weekly Maintenance
- ✓ Review backup logs
- ✓ Check snapshot retention
- ✓ Monitor disk usage
- ✓ Check Btrfs stats: `btrfs device stats /srv/nas`

### Monthly Maintenance
- ✓ Run Btrfs scrub: `btrfs scrub start /srv/nas`
- ✓ Test disaster recovery (restore single file)
- ✓ Update system: `yay -Syu`
- ✓ Review security logs

### Quarterly Maintenance
- ✓ Full backup verification
- ✓ Review and rotate passwords
- ✓ Test complete disaster recovery
- ✓ Review and update threat model

---

## Performance Considerations

### Expected Performance

| Operation | Speed | Notes |
|-----------|-------|-------|
| Local read | ~500 MB/s | SSD-limited |
| Local write | ~400 MB/s | Encryption overhead ~5% |
| Remote read (Tailscale) | ~50-100 MB/s | Network-limited |
| Remote write (Tailscale) | ~50-100 MB/s | Network-limited |
| Snapshot creation | <1 second | Instant (COW) |
| Proton backup (initial) | ~10 MB/s | Upload-limited |
| Proton backup (incremental) | ~1-5 MB/s | Depends on changes |

### Optimization Tips

1. **For SSDs**: Enable `discard=async` and `ssd` mount options
2. **For HDDs**: Enable `autodefrag` mount option
3. **For large files**: Increase `rclone --transfers` to 8
4. **For many small files**: Increase `rclone --checkers` to 16
5. **For low bandwidth**: Reduce Proton sync frequency to weekly

---

## Conclusion

This architecture provides:
- ✓ **Confidentiality**: Multi-layer encryption
- ✓ **Integrity**: Checksums and atomic operations
- ✓ **Availability**: Snapshots and backups
- ✓ **Modularity**: Easy to add/remove
- ✓ **Convenience**: Auto-unlock, auto-backup
- ✓ **Privacy**: End-to-end encryption, no metadata leakage

The design prioritizes **security and data integrity** while maintaining **usability and automation**.
