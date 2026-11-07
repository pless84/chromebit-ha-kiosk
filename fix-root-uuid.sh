#!/usr/bin/env bash
# Re-point an already-built Chromebit stick at its root filesystem UUID instead of the
# stick's partition GUID, so the same kernel + rootfs also boot after being dd'ed to eMMC.
#
# Usage:  sudo ./fix-root-uuid.sh /dev/sdX
set -euo pipefail

DEV="${1:-}"
WORK="${WORK:-/var/tmp/chromebit-build}"
ROOT="$WORK/rootfs"
MNT="$WORK/mnt"
if [ -f "$(dirname "$0")/local.env" ]; then . "$(dirname "$0")/local.env"; fi
REGDOM="${REGDOM:-US}"
MAX_IMG=$((16 * 1024 * 1024))

die() { echo "ERROR: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -b "$DEV" ] || die "usage: sudo $0 /dev/sdX"
[ "$(lsblk -dno TRAN "$DEV")" = usb ] || die "$DEV is not a USB disk; refusing"
KPART="${DEV}1"; RPART="${DEV}2"
[ "$(cgpt show -i 1 -t "$DEV")" = "FE3A2A5D-4F32-41A7-B725-ACCC3285A309" ] || die "$KPART is not a ChromeOS kernel partition"
[ "$(blkid -s LABEL -o value "$RPART")" = chromebit-root ] || die "$RPART is not the chromebit-root filesystem"
[ -x "$WORK/venv/bin/mkdepthcharge" ] || die "build venv missing; run build-usb.sh first"

FSUUID=$(blkid -s UUID -o value "$RPART")
echo "root filesystem UUID: $FSUUID"

trap 'mountpoint -q "$MNT" && umount "$MNT" || true' EXIT
for p in "$KPART" "$RPART"; do umount "$p" 2>/dev/null || true; done
mkdir -p "$MNT"
mount "$RPART" "$MNT"
echo "UUID=$FSUUID  /  ext4  defaults,noatime,commit=60  0 1" > "$MNT/etc/fstab"
cp "$MNT/etc/fstab" "$ROOT/etc/fstab"
VMLINUZ=$(find "$MNT/boot" -maxdepth 1 -name 'vmlinuz-*-armmp' | sort -V | tail -1)
KVER=${VMLINUZ##*/vmlinuz-}
cp "$VMLINUZ" "$MNT/boot/initrd.img-$KVER" "$MNT/usr/lib/linux-image-$KVER/rk3288-veyron-mickey.dtb" "$WORK/"
umount "$MNT"

CMDLINE="root=UUID=$FSUUID rootwait rw console=tty1 cfg80211.ieee80211_regdom=$REGDOM gpt"
rm -f "$WORK/kernel.img"
PYTHONWARNINGS=ignore "$WORK/venv/bin/mkdepthcharge" -o "$WORK/kernel.img" -A arm --format fit \
  --kernel-start 0x2000000 --patch-dtbs --keydir /usr/share/vboot/devkeys \
  -c "$CMDLINE" \
  -d "$WORK/vmlinuz-$KVER" -i "$WORK/initrd.img-$KVER" -b "$WORK/rk3288-veyron-mickey.dtb"
[ "$(stat -c %s "$WORK/kernel.img")" -le "$MAX_IMG" ] || die "kernel image over 16 MiB"
dd if="$WORK/kernel.img" of="$KPART" bs=1M conv=fsync status=none
sync
futility vbutil_kernel --verify "$KPART" | grep -A1 '^Config'
echo "done: stick now boots with root=UUID=$FSUUID"
