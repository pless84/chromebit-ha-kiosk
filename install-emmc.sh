#!/usr/bin/env bash
# Copy the running Debian (booted from the USB stick) onto the Chromebit's internal eMMC.
#
# Run on the Chromebit:  sudo bash install-emmc.sh kernel-emmc.img
#   kernel-emmc.img = signed depthcharge kernel whose command line has root=UUID=<this root> and "gpt"
#   (build-usb.sh adds "gpt" since 2026-11-07, so its /var/tmp/chromebit-build/kernel.img works).
#
# Why it's odd: on some units the first 4 MiB of the eMMC (blocks 0-8191) are PERMANENTLY
# write-protected, and the primary GPT header there reads "IGNOREME". ChromeOS firmware then
# uses only the backup GPT at the end of the disk. On such a unit this script:
#   - never writes the first 4 MiB,
#   - writes only the backup GPT (last 33 sectors), partitions start at sector 8192,
#   - writes kernel and root by sector offset (the running kernel can't see the partitions),
#   - needs "gpt" on the kernel command line, or Linux ignores a backup-only GPT and can't find root.
# On a normal eMMC (no IGNOREME) it writes both GPT copies; the same partition layout is used.
# The eMMC root gets the same filesystem UUID as the stick: never boot with both plugged in.
set -euo pipefail

KIMG="${1:-}"
EMMC=/dev/mmcblk0
MNT=/mnt/emmc
WORK=/var/tmp/emmc-install
KSTART=8192; KSIZE=65536                  # 32 MiB kernel partition, right after the protected area
RSTART=$((KSTART + KSIZE))
die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$KIMG" ] || die "usage: sudo bash $0 kernel-emmc.img"
[ -b "$EMMC" ] || die "$EMMC not found"
ROOTDEV=$(findmnt -no SOURCE /)
case "$ROOTDEV" in /dev/sd*2) ;; *) die "root is $ROOTDEV; run this while booted from the USB stick" ;; esac
FSUUID=$(findmnt -no UUID /)
[ "$(blkid -s LABEL -o value "$ROOTDEV")" = chromebit-root ] || die "$ROOTDEV is not chromebit-root"
[ "$(stat -c %s "$KIMG")" -le $((KSIZE * 512)) ] || die "kernel image bigger than the kernel partition"

step "installing tools"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends cgpt vboot-kernel-utils rsync e2fsprogs >/dev/null

step "checking the kernel image"
CFG=$(futility vbutil_kernel --verify "$KIMG" | grep -A1 '^Config' | tail -1)
echo "$CFG"
case " $CFG " in *" root=UUID=$FSUUID "*) ;; *) die "kernel command line does not use root=UUID=$FSUUID" ;; esac
case " $CFG " in *" gpt "*) ;; *) die "kernel command line is missing 'gpt'" ;; esac
if [ "$(dd if="$EMMC" bs=1 skip=512 count=8 status=none)" = IGNOREME ]; then
  LOCKED=1
  echo "primary GPT is IGNOREME (write-protected start): writing only the backup GPT"
else
  LOCKED=0
  echo "normal eMMC layout: writing both GPT copies"
fi

SECTORS=$(blockdev --getsz "$EMMC")
RSIZE=$((SECTORS - RSTART - 2048))
echo
echo "This ERASES the internal storage ($EMMC, $((SECTORS / 2048)) MiB) and copies Debian onto it."
read -r -p "Type ERASE to continue: " ok
[ "$ok" = ERASE ] || die "aborted"

step "writing partition table"
mkdir -p "$WORK"
rm -f "$WORK/disk.img"
truncate -s $((SECTORS * 512)) "$WORK/disk.img"      # sparse, same size as the eMMC
cgpt create "$WORK/disk.img"
cgpt add -i 1 -t kernel -b $KSTART -s $KSIZE -l KERN-A -S 1 -T 0 -P 15 "$WORK/disk.img"
cgpt add -i 2 -t data   -b $RSTART -s $RSIZE -l ROOT "$WORK/disk.img"
dd if="$WORK/disk.img" of="$EMMC" bs=512 skip=$((SECTORS - 33)) seek=$((SECTORS - 33)) count=33 \
  oflag=direct conv=fsync status=none
if [ "$LOCKED" = 0 ]; then
  # protective MBR + primary header + primary entries
  dd if="$WORK/disk.img" of="$EMMC" bs=512 count=34 oflag=direct conv=fsync status=none
fi
rm -f "$WORK/disk.img"
cgpt show "$EMMC" 2>&1 | grep -E 'KERN-A|ROOT|priority' || die "eMMC GPT not readable after write"

step "writing kernel"
# KSTART=8192 sectors = 4 MiB, KSIZE=65536 sectors = 32 MiB
dd if=/dev/zero of="$EMMC" bs=1M seek=4 count=32 oflag=direct conv=fsync status=none
dd if="$KIMG" of="$EMMC" bs=1M seek=4 oflag=direct conv=fsync status=none
dd if="$EMMC" of="$WORK/kcheck.img" bs=1M skip=4 count=32 status=none
futility vbutil_kernel --verify "$WORK/kcheck.img" >/dev/null && echo "kernel on eMMC verifies"
rm -f "$WORK/kcheck.img"

step "copying root filesystem (a few minutes)"
LOOP=$(losetup -f --show -o $((RSTART * 512)) --sizelimit $((RSIZE * 512)) "$EMMC")
trap 'mountpoint -q "$MNT" && umount "$MNT"; losetup -d "$LOOP" 2>/dev/null || true' EXIT
mkfs.ext4 -F -q -L chromebit-root -U "$FSUUID" "$LOOP"
mkdir -p "$MNT"
mount "$LOOP" "$MNT"
rsync -aHAXx --numeric-ids \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' \
  --exclude='/tmp/*' --exclude='/mnt/*' --exclude='/media/*' --exclude='/var/tmp/*' \
  / "$MNT"/
echo "used: $(df -h --output=used "$MNT" | tail -1)"
umount "$MNT"
sync

step "done"
echo "Now: sudo poweroff, REMOVE the USB stick, power on. At 'OS verification is OFF' press Ctrl+D (or wait 30 s)."
