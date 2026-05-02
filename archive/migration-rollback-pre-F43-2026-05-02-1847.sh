#!/usr/bin/env bash
# Rollback to btrfs snapshot taken 2026-05-02T18:47:18+10:00: root_pre-F43-2026-05-02-1847
# Run this from a Fedora live USB or rescue console - NOT from the running system.
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then echo "must be root" >&2; exit 1; fi

mkdir -p /mnt/btrfs-rb
mount -o subvolid=5 /dev/nvme0n1p6 /mnt/btrfs-rb

# Save the broken root for forensics
broken="root_broken_$(date +%Y%m%d-%H%M)"
echo "saving broken root as $broken"
btrfs subvolume snapshot /mnt/btrfs-rb/root /mnt/btrfs-rb/$broken

# Replace root with a writable copy of the snapshot
echo "deleting current root and replacing with root_pre-F43-2026-05-02-1847"
btrfs subvolume delete /mnt/btrfs-rb/root
btrfs subvolume snapshot /mnt/btrfs-rb/root_pre-F43-2026-05-02-1847 /mnt/btrfs-rb/root

umount /mnt/btrfs-rb
echo "rollback complete - reboot the host"
