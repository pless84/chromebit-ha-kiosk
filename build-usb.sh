#!/usr/bin/env bash
# Build a Debian 13 "trixie" (armhf) USB stick that boots on the ASUS Chromebit CS10
# (veyron_mickey) in developer mode (Ctrl+U, or dev_default_boot=usb).
#
# Usage:  sudo ./build-usb.sh /dev/sdX
#
# Needs (Fedora): debootstrap qemu-user-static vboot-utils uboot-tools python3 rsync
# The stick is wiped only after the system and kernel image are built.
# The chroot build is cached in $WORK, so re-runs are faster.

set -euo pipefail

DEV="${1:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Personal settings (KBD_LAYOUT, REGDOM, ...) can live in local.env next to this script (not in git).
if [ -f "$HERE/local.env" ]; then . "$HERE/local.env"; fi
FW="$HERE/firmware"
WORK="${WORK:-/var/tmp/chromebit-build}"
ROOT="$WORK/rootfs"
MNT="$WORK/mnt"
SUITE=trixie
MIRROR=http://deb.debian.org/debian
HOSTNAME_NEW=chromebit
KBD_LAYOUT="${KBD_LAYOUT:-us}"   # console keyboard layout, e.g. us, de, dk
REGDOM="${REGDOM:-US}"           # Wi-Fi country code: set it to yours, e.g. DE, DK, GB
KVER_GLOB='*-armmp'
MAX_IMG=$((16 * 1024 * 1024))   # veyron depthcharge loads at most 16 MiB
APT_OPTS=(-y --no-install-recommends -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

# ---------- preflight ----------
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -n "$DEV" ] || die "usage: sudo $0 /dev/sdX"
[ -b "$DEV" ] || die "$DEV is not a block device"
[ "$(lsblk -dno TYPE "$DEV")" = disk ] || die "$DEV is not a whole disk (give /dev/sdX, not /dev/sdX1)"
[ "$(lsblk -dno TRAN "$DEV")" = usb ] || die "$DEV is not a USB disk; refusing"
SIZE_B=$(blockdev --getsize64 "$DEV")
[ "$SIZE_B" -le $((64 * 1024 * 1024 * 1024)) ] || die "$DEV is bigger than 64 GB; refusing"
[ "$SIZE_B" -ge $((1500 * 1024 * 1024)) ] || die "$DEV is smaller than 1.5 GB"
[ "$(blockdev --getss "$DEV")" -eq 512 ] || die "$DEV does not use 512-byte sectors"
for f in brcmfmac4354-sdio.txt brcmfmac4354-sdio.bin; do
  [ -f "$FW/$f" ] || die "missing $FW/$f (the files copied from ChromeOS)"
done
for c in debootstrap cgpt futility mkimage python3 rsync mkfs.ext4 wipefs partprobe; do
  command -v "$c" >/dev/null || die "missing command: $c"
done
[ -e /proc/sys/fs/binfmt_misc/qemu-arm ] || die "qemu-arm binfmt not registered (install qemu-user-static)"

USER_NEW="${SUDO_USER:-chromebit}"
USER_HOME=$(getent passwd "$USER_NEW" | cut -d: -f6 || true)

echo "Target stick:"
lsblk -o NAME,SIZE,MODEL,TRAN,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
echo
echo "EVERYTHING on $DEV will be erased (after the build succeeds)."
read -r -p "Type ERASE to continue: " ok
[ "$ok" = ERASE ] || die "aborted"

echo
echo "Login user on the Chromebit will be: $USER_NEW"
read -r -s -p "Choose a password for $USER_NEW (console + sudo): " PW1; echo
read -r -s -p "Repeat password: " PW2; echo
[ -n "$PW1" ] && [ "$PW1" = "$PW2" ] || die "passwords empty or different"
read -r -p "Wi-Fi network name (SSID): " SSID
read -r -s -p "Wi-Fi password: " WIFIPW; echo
[ -n "$SSID" ] || die "SSID empty"
case "$SSID$WIFIPW" in *\\*) die "backslashes in SSID/password are not supported here; set Wi-Fi up with nmtui later" ;; esac
if ! { [ ${#WIFIPW} -ge 8 ] && [ ${#WIFIPW} -le 63 ]; } && ! [[ "$WIFIPW" =~ ^[0-9A-Fa-f]{64}$ ]]; then
  die "WPA password must be 8-63 characters"
fi
[ "$WIFIPW" = "$(echo "$WIFIPW" | sed 's/^ *//;s/ *$//')" ] || die "Wi-Fi password starts/ends with a space; not supported here"

# ---------- cleanup on exit ----------
umount_chroot() {
  for m in dev/pts dev proc sys run; do
    mountpoint -q "$ROOT/$m" && umount -l "$ROOT/$m" || true
  done
}
cleanup() {
  umount_chroot
  mountpoint -q "$MNT" && umount "$MNT" || true
}
trap cleanup EXIT

in_chroot() {
  chroot "$ROOT" /usr/bin/env -i \
    PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 \
    DEBIAN_FRONTEND=noninteractive "$@"
}

mkdir -p "$WORK" "$MNT"
umount_chroot   # in case an earlier run was killed

# ---------- 1. base system ----------
if [ ! -f "$ROOT/.debootstrap-done" ]; then
  step "debootstrap $SUITE armhf (slow under emulation, ~10-20 min)"
  rm -rf --one-file-system "$ROOT"
  debootstrap --arch=armhf --variant=minbase \
    --components=main,non-free-firmware \
    --include=systemd-sysv,udev,dbus,kmod,ca-certificates,apt-utils \
    "$SUITE" "$ROOT" "$MIRROR"
  touch "$ROOT/.debootstrap-done"
else
  step "reusing base system in $ROOT"
fi

mount --bind /dev "$ROOT/dev"
mount --bind /dev/pts "$ROOT/dev/pts"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sys "$ROOT/sys"
mount -t tmpfs tmpfs "$ROOT/run"
rm -f "$ROOT/etc/resolv.conf"
cp -L /etc/resolv.conf "$ROOT/etc/resolv.conf"

# keep services from starting inside the chroot
printf '#!/bin/sh\nexit 101\n' > "$ROOT/usr/sbin/policy-rc.d"
chmod +x "$ROOT/usr/sbin/policy-rc.d"

cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $SUITE main non-free-firmware
deb $MIRROR $SUITE-updates main non-free-firmware
deb http://security.debian.org/debian-security $SUITE-security main non-free-firmware
EOF

# ---------- 2. initramfs + keyboard config (before packages are installed) ----------
step "configuring a small initramfs (image must stay under 16 MiB)"
mkdir -p "$ROOT/etc/initramfs-tools/conf.d"
cat > "$ROOT/etc/initramfs-tools/conf.d/chromebit.conf" <<'EOF'
MODULES=list
COMPRESS=zstd
EOF
cat > "$ROOT/etc/initramfs-tools/modules" <<'EOF'
# RK3288 / veyron-mickey: PMIC + regulators, dwc2 USB host, SD/eMMC, ext4
i2c_rk3x
rk808_regulator
clk_rk808
pwm_rockchip
io_domain
phy_rockchip_usb
dwc2
usb_storage
uas
sd_mod
dw_mmc
dw_mmc_pltfm
dw_mmc_rockchip
ext4
crc32c_generic
EOF

cat > "$ROOT/etc/default/keyboard" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="$KBD_LAYOUT"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF

step "installing kernel and packages"
in_chroot apt-get update
in_chroot apt-get install "${APT_OPTS[@]}" initramfs-tools zstd
in_chroot apt-get install "${APT_OPTS[@]}" \
  linux-image-armmp firmware-brcm80211 \
  network-manager wpasupplicant iw wireless-regdb \
  openssh-server sudo avahi-daemon libnss-mdns \
  systemd-timesyncd zram-tools e2fsprogs \
  console-setup keyboard-configuration \
  nano less iproute2 iputils-ping curl htop
# make sure the initrd matches the config above, also on re-runs
in_chroot update-initramfs -u -k all

# ---------- 3. Wi-Fi / Bluetooth firmware from ChromeOS ----------
step "installing Chromebit Wi-Fi settings file"
FWDIR="$ROOT/usr/lib/firmware/brcm"
mkdir -p "$FWDIR"
install -m644 "$FW/brcmfmac4354-sdio.txt" "$FWDIR/brcmfmac4354-sdio.txt"
install -m644 "$FW/brcmfmac4354-sdio.txt" "$FWDIR/brcmfmac4354-sdio.google,veyron-mickey-rev8.txt"
if ! ls "$FWDIR"/brcmfmac4354-sdio.bin* >/dev/null 2>&1; then
  echo "Debian has no brcmfmac4354-sdio.bin; using the ChromeOS copy"
  install -m644 "$FW/brcmfmac4354-sdio.bin" "$FWDIR/brcmfmac4354-sdio.bin"
fi
mkdir -p "$ROOT/root/chromeos-firmware"
cp "$FW"/* "$ROOT/root/chromeos-firmware/"    # fallback copies
if [ -f "$FW/BCM4354.hcd" ]; then install -m644 "$FW/BCM4354.hcd" "$FWDIR/BCM4354A2.hcd"; fi

# ---------- 4. system config ----------
step "configuring hostname, user, network, ssh"
echo "$HOSTNAME_NEW" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1 localhost
127.0.1.1 $HOSTNAME_NEW
::1 localhost ip6-localhost ip6-loopback
EOF

if ! in_chroot id "$USER_NEW" >/dev/null 2>&1; then
  in_chroot useradd -m -s /bin/bash -G sudo "$USER_NEW"
fi
printf '%s:%s\n' "$USER_NEW" "$PW1" | in_chroot chpasswd
unset PW1 PW2

if [ -n "$USER_HOME" ] && ls "$USER_HOME"/.ssh/*.pub >/dev/null 2>&1; then
  install -d -m700 "$ROOT/home/$USER_NEW/.ssh"
  cat "$USER_HOME"/.ssh/*.pub > "$ROOT/home/$USER_NEW/.ssh/authorized_keys"
  chmod 600 "$ROOT/home/$USER_NEW/.ssh/authorized_keys"
  in_chroot chown -R "$USER_NEW:$USER_NEW" "/home/$USER_NEW/.ssh"
  echo "added your SSH public key(s)"
fi

NMDIR="$ROOT/etc/NetworkManager/system-connections"
mkdir -p "$NMDIR"
rm -f "$NMDIR/home-wifi.nmconnection"
UUID_WIFI=$(cat /proc/sys/kernel/random/uuid)
cat > "$NMDIR/home-wifi.nmconnection" <<EOF
[connection]
id=home-wifi
uuid=$UUID_WIFI
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=$SSID

[wifi-security]
key-mgmt=wpa-psk
psk=$WIFIPW

[ipv4]
method=auto

[ipv6]
method=auto
EOF
chmod 600 "$NMDIR/home-wifi.nmconnection"
unset WIFIPW
mkdir -p "$ROOT/etc/NetworkManager/conf.d"
cat > "$ROOT/etc/NetworkManager/conf.d/wifi-powersave-off.conf" <<'EOF'
[connection]
wifi.powersave = 2
EOF

# show the IP address on the TV login screen
grep -q 'IP address' "$ROOT/etc/issue" || printf 'IP address: \\4\n\n' >> "$ROOT/etc/issue"

# IDs are chosen now, so fstab + kernel cmdline exist before the stick is touched.
# Root is found by filesystem UUID, so the same image also boots after a dd to eMMC.
ROOT_PARTUUID=$(cat /proc/sys/kernel/random/uuid)
ROOT_FSUUID=$(cat /proc/sys/kernel/random/uuid)
cat > "$ROOT/etc/fstab" <<EOF
UUID=$ROOT_FSUUID  /  ext4  defaults,noatime,commit=60  0 1
EOF

umount_chroot
rm -f "$ROOT/usr/sbin/policy-rc.d"
rm -rf "$ROOT"/var/cache/apt/archives/*.deb

# ---------- 5. kernel image (built before the stick is wiped) ----------
step "building signed depthcharge kernel image"
VENV="$WORK/venv"
if [ ! -x "$VENV/bin/mkdepthcharge" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install depthcharge-tools "setuptools<81"
fi
VMLINUZ=$(find "$ROOT/boot" -maxdepth 1 -name "vmlinuz-$KVER_GLOB" | sort -V | tail -1)
[ -n "$VMLINUZ" ] || die "no armmp kernel found in $ROOT/boot"
KVER=${VMLINUZ##*/vmlinuz-}
INITRD="$ROOT/boot/initrd.img-$KVER"
DTB="$ROOT/usr/lib/linux-image-$KVER/rk3288-veyron-mickey.dtb"
for f in "$VMLINUZ" "$INITRD" "$DTB"; do [ -f "$f" ] || die "missing $f"; done
echo "kernel $KVER, initramfs $(du -h "$INITRD" | cut -f1)"

CMDLINE="root=UUID=$ROOT_FSUUID rootwait rw console=tty1 cfg80211.ieee80211_regdom=$REGDOM gpt"
rm -f "$WORK/kernel.img"
PYTHONWARNINGS=ignore "$VENV/bin/mkdepthcharge" -o "$WORK/kernel.img" -A arm --format fit \
  --kernel-start 0x2000000 --patch-dtbs \
  --keydir /usr/share/vboot/devkeys \
  -c "$CMDLINE" \
  -d "$VMLINUZ" -i "$INITRD" -b "$DTB"
IMG_B=$(stat -c %s "$WORK/kernel.img")
echo "kernel image: $((IMG_B / 1024)) KiB"
[ "$IMG_B" -le "$MAX_IMG" ] || die "kernel image is over 16 MiB; the Chromebit cannot load it"

# ---------- 6. partition the stick ----------
step "partitioning $DEV"
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
  umount "$p" 2>/dev/null || true
  wipefs -a "$p" || true
done
wipefs -a "$DEV"
SECTORS=$(blockdev --getsz "$DEV")
KSTART=8192; KSIZE=65536                       # 32 MiB kernel partition
RSTART=$((KSTART + KSIZE))
RSIZE=$((SECTORS - RSTART - 2048))             # leave room for backup GPT
# clear any old filesystem signatures where the new partitions will start
dd if=/dev/zero of="$DEV" bs=512 seek=$KSTART count=$((KSIZE + 8192)) conv=fsync status=none
cgpt create "$DEV"
cgpt add -i 1 -t kernel -b $KSTART -s $KSIZE -l KERN-A -S 1 -T 5 -P 10 "$DEV"
cgpt add -i 2 -t data   -b $RSTART -s $RSIZE -l ROOT -u "$ROOT_PARTUUID" "$DEV"
cgpt boot -p "$DEV"
partprobe "$DEV"; udevadm settle
case "$DEV" in *[0-9]) P="${DEV}p" ;; *) P="$DEV" ;; esac
KPART="${P}1"; RPART="${P}2"
[ -b "$RPART" ] || die "$RPART did not appear"
GOT=$(cgpt show -i 2 -u "$DEV" | tr 'A-Z' 'a-z')
[ "$GOT" = "$ROOT_PARTUUID" ] || die "root PARTUUID mismatch ($GOT vs $ROOT_PARTUUID)"

umount "$RPART" 2>/dev/null || true
mkfs.ext4 -F -L chromebit-root -U "$ROOT_FSUUID" "$RPART"

# ---------- 7. copy root filesystem + kernel ----------
step "copying root filesystem to the stick"
mount "$RPART" "$MNT"
rsync -aHAX --numeric-ids --exclude=/.debootstrap-done \
  --exclude='/dev/*' --exclude='/proc/*' --exclude='/sys/*' --exclude='/run/*' --exclude='/tmp/*' \
  "$ROOT"/ "$MNT"/
# drop SELinux labels picked up on the Fedora host
find "$MNT" -xdev -exec setfattr -h -x security.selinux {} + 2>/dev/null || true
# let NetworkManager write resolv.conf on the device
rm -f "$MNT/etc/resolv.conf"
: > "$MNT/etc/resolv.conf"
echo "used on stick: $(df -h --output=used "$MNT" | tail -1)"
umount "$MNT"

dd if="$WORK/kernel.img" of="$KPART" bs=1M conv=fsync status=none
sync

step "done"
cgpt show "$DEV"
echo
echo "Next: put the stick in the Chromebit and power on. At the 'OS verification is OFF'"
echo "screen press Ctrl+U (or wait, if dev_default_boot=usb is set)."
echo "Log in as $USER_NEW on the TV, or: ssh $USER_NEW@$HOSTNAME_NEW.local"
