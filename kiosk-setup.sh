#!/usr/bin/env bash
# Turn the Debian Chromebit into a full-screen Home Assistant touchscreen kiosk.
#
# Run on the Chromebit as root, or from another machine:
#   ssh chromebit.local 'sudo bash -s' < kiosk-setup.sh
# Safe to run again. Settings (URL, night hours) live in /etc/default/kiosk afterwards;
# edit that file and run `sudo systemctl restart getty@tty1` to apply.
#
# Stack: getty autologin (user "kiosk") -> cage (Wayland kiosk compositor) -> browser.
# Screen off at night via kiosk-screen.timer (checks every 5 minutes, also right after boot).

set -euo pipefail

KIOSK_USER=kiosk
# Override on the first run, e.g.:
#   ssh chromebit.local 'sudo KIOSK_URL=http://192.168.1.10:8123/ TIMEZONE=Europe/Berlin bash -s' < kiosk-setup.sh
TIMEZONE="${TIMEZONE:-}"   # night hours follow local time; empty = keep the system's timezone
DEFAULT_URL="${KIOSK_URL:-http://homeassistant.local:8123/}"
DEFAULT_OFF="23:00"
DEFAULT_ON="07:00"
APT_OPTS=(-y --no-install-recommends)

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
[ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
[ "$(dpkg --print-architecture)" = armhf ] || echo "warning: not armhf; continuing anyway"
export DEBIAN_FRONTEND=noninteractive

# (no "| grep -q": with pipefail, grep closing the pipe early makes the check fail)
has_candidate() { local p; p=$(apt-cache policy "$1" 2>/dev/null); [[ "$p" =~ Candidate:\ [^\(] ]]; }

# ---------- packages ----------
step "installing packages"
apt-get update
apt-get install "${APT_OPTS[@]}" \
  cage libpam-systemd dbus-user-session \
  libgl1-mesa-dri libegl1 libgles2 mesa-utils-bin \
  wlr-randr libinput-tools \
  fonts-noto-core fonts-noto-color-emoji \
  zram-tools grim
if [ -n "$TIMEZONE" ]; then timedatectl set-timezone "$TIMEZONE"; fi
echo "timezone: $(timedatectl show -p Timezone --value)"
if has_candidate wlopm; then apt-get install "${APT_OPTS[@]}" wlopm; fi

if has_candidate chromium; then
  BROWSER=chromium
elif has_candidate firefox-esr; then
  BROWSER=firefox-esr
else
  die "neither chromium nor firefox-esr is available for this architecture"
fi
apt-get install "${APT_OPTS[@]}" "$BROWSER"
echo "browser: $BROWSER"

# ---------- settings file ----------
step "writing /etc/default/kiosk"
if [ ! -f /etc/default/kiosk ]; then
  cat > /etc/default/kiosk <<EOF
# Home Assistant kiosk settings. Apply with: sudo systemctl restart getty@tty1
KIOSK_URL="$DEFAULT_URL"
KIOSK_BROWSER="$BROWSER"
# Screen off from SCREEN_OFF until SCREEN_ON (24 h clock). Set both empty to keep it always on.
SCREEN_OFF="$DEFAULT_OFF"
SCREEN_ON="$DEFAULT_ON"
# Extra browser flags, e.g. "--disable-gpu" if the screen shows glitches.
KIOSK_EXTRA_FLAGS=""
EOF
else
  sed -i "s|^KIOSK_BROWSER=.*|KIOSK_BROWSER=\"$BROWSER\"|" /etc/default/kiosk
  echo "kept existing settings"
fi

# ---------- kiosk user + autologin ----------
step "kiosk user and autologin on tty1"
if ! id "$KIOSK_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$KIOSK_USER"
fi
passwd -l "$KIOSK_USER" >/dev/null
usermod -aG video,render,input,audio "$KIOSK_USER"

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

# ---------- launcher ----------
step "installing /usr/local/bin/kiosk-browser"
cat > /usr/local/bin/kiosk-browser <<'EOF'
#!/bin/bash
# Started by cage. Runs the browser full screen on the HA dashboard.
. /etc/default/kiosk
case "$KIOSK_BROWSER" in
  chromium)
    PREFS="$HOME/.config/chromium/Default/Preferences"
    # don't show "Chromium didn't shut down correctly" after a power cut
    [ -f "$PREFS" ] && sed -i 's/"exited_cleanly":false/"exited_cleanly":true/; s/"exit_type":"[^"]*"/"exit_type":"Normal"/' "$PREFS"
    # shellcheck disable=SC2086
    # --force-dark-mode: pages see prefers-color-scheme: dark (HA's default theme follows it)
    exec chromium --ozone-platform=wayland --kiosk --force-dark-mode --noerrdialogs --disable-infobars \
      --no-first-run --disable-session-crashed-bubble --disable-features=Translate \
      --check-for-update-interval=31536000 --password-store=basic \
      --touch-events=enabled --disable-pinch --overscroll-history-navigation=0 \
      --disk-cache-size=50000000 $KIOSK_EXTRA_FLAGS "$KIOSK_URL"
    ;;
  firefox-esr)
    export MOZ_ENABLE_WAYLAND=1
    # shellcheck disable=SC2086
    exec firefox-esr --kiosk $KIOSK_EXTRA_FLAGS "$KIOSK_URL"
    ;;
esac
EOF
chmod 755 /usr/local/bin/kiosk-browser

cat > "/home/$KIOSK_USER/.bash_profile" <<'EOF'
# Only on the physical console: run the kiosk, restart it if it exits.
if [ "$(tty)" = /dev/tty1 ] && [ -z "$WAYLAND_DISPLAY" ]; then
  export XCURSOR_THEME=invisible XCURSOR_SIZE=24   # touch screen: no visible mouse pointer
  while true; do
    cage -s -- /usr/local/bin/kiosk-browser >"$HOME/kiosk.log" 2>&1
    sleep 3
  done
fi
EOF
chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.bash_profile"

# ---------- invisible cursor ----------
# cage and Chromium both draw the pointer from the XCURSOR_THEME. This theme's every cursor is
# one transparent pixel, so nothing shows on the touch screen.
step "installing invisible cursor theme"
CUR=/usr/share/icons/invisible/cursors
mkdir -p "$CUR"
printf 'Xcur\020\0\0\0\0\0\001\0\001\0\0\0\002\0\375\377\001\0\0\0\034\0\0\0\044\0\0\0\002\0\375\377\001\0\0\0\001\0\0\0\001\0\0\0\001\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0' > "$CUR/default"
for n in left_ptr arrow top_left_arrow pointer hand hand1 hand2 pointing_hand text xterm ibeam \
         wait watch progress left_ptr_watch crosshair cross move fleur grab grabbing all-scroll \
         not-allowed crossed_circle help question_arrow context-menu copy alias cell vertical-text \
         col-resize row-resize ew-resize ns-resize nesw-resize nwse-resize n-resize s-resize e-resize \
         w-resize ne-resize nw-resize se-resize sw-resize sb_h_double_arrow sb_v_double_arrow \
         size_hor size_ver size_bdiag size_fdiag zoom-in zoom-out no-drop dnd-none; do
  ln -sf default "$CUR/$n"
done
printf '[Icon Theme]\nName=invisible\nComment=Transparent cursors for the kiosk\n' > /usr/share/icons/invisible/index.theme
# cage may ask for the "default" theme instead of $XCURSOR_THEME: make the kiosk user's default invisible too
install -d -o "$KIOSK_USER" -g "$KIOSK_USER" "/home/$KIOSK_USER/.icons/default"
printf '[Icon Theme]\nInherits=invisible\n' > "/home/$KIOSK_USER/.icons/default/index.theme"
chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.icons/default/index.theme"
# The HDMI port's CEC remote input (dw_hdmi) reports itself as a pointer, which makes cage
# show a mouse cursor. Nothing here uses CEC remotes, so libinput ignores it.
cat > /etc/udev/rules.d/90-kiosk-ignore-hdmi-input.rules <<'EOF'
ACTION=="add|change", SUBSYSTEM=="input", ATTRS{name}=="dw_hdmi", ENV{LIBINPUT_IGNORE_DEVICE}="1"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=input --action=change

# ---------- night screen schedule ----------
step "installing screen schedule"
cat > /usr/local/bin/kiosk-screen <<'EOF'
#!/bin/bash
# kiosk-screen on|off|auto   (auto = follow SCREEN_OFF/SCREEN_ON in /etc/default/kiosk)
. /etc/default/kiosk
U=$(id -u kiosk)
export XDG_RUNTIME_DIR=/run/user/$U
SOCK=$(ls "$XDG_RUNTIME_DIR"/wayland-* 2>/dev/null | grep -v '\.lock$' | head -1)
[ -n "$SOCK" ] || { echo "kiosk is not running"; exit 0; }
export WAYLAND_DISPLAY=${SOCK##*/}

want=$1
if [ "$want" = auto ]; then
  [ -n "$SCREEN_OFF" ] && [ -n "$SCREEN_ON" ] || want=on
fi
if [ "$want" = auto ]; then
  now=$(date +%H%M); off=${SCREEN_OFF/:/}; on=${SCREEN_ON/:/}
  if [ "$off" -gt "$on" ]; then          # e.g. 23:00 -> 07:00 crosses midnight
    { [ "$now" -ge "$off" ] || [ "$now" -lt "$on" ]; } && want=off || want=on
  else
    { [ "$now" -ge "$off" ] && [ "$now" -lt "$on" ]; } && want=off || want=on
  fi
fi
run() { runuser -u kiosk -- env XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" WAYLAND_DISPLAY="$WAYLAND_DISPLAY" "$@"; }
if command -v wlopm >/dev/null && run wlopm --"$want" '*' 2>/dev/null; then
  exit 0
fi
# fallback: turn the output off/on with wlr-randr
OUT=$(run wlr-randr 2>/dev/null | awk 'NR==1{print $1}')
[ -n "$OUT" ] && run wlr-randr --output "$OUT" --"$want"
EOF
chmod 755 /usr/local/bin/kiosk-screen

cat > /etc/systemd/system/kiosk-screen.service <<'EOF'
[Unit]
Description=Turn the kiosk screen on or off by time of day
[Service]
Type=oneshot
ExecStart=/usr/local/bin/kiosk-screen auto
EOF
cat > /etc/systemd/system/kiosk-screen.timer <<'EOF'
[Unit]
Description=Check kiosk screen schedule every 5 minutes
[Timer]
OnBootSec=2min
OnCalendar=*:0/5
[Install]
WantedBy=timers.target
EOF

# daily restart of the browser session, clears memory creep
cat > /etc/systemd/system/kiosk-restart.service <<'EOF'
[Unit]
Description=Restart the kiosk session
[Service]
Type=oneshot
ExecStart=/bin/systemctl restart getty@tty1.service
ExecStartPost=/bin/sh -c 'sleep 60; /usr/local/bin/kiosk-screen auto'
EOF
cat > /etc/systemd/system/kiosk-restart.timer <<'EOF'
[Unit]
Description=Restart the kiosk session daily at 04:00
[Timer]
OnCalendar=*-*-* 04:00
[Install]
WantedBy=timers.target
EOF

# ---------- memory ----------
step "zram swap and swappiness"
cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
echo 'vm.swappiness=100' > /etc/sysctl.d/90-kiosk.conf
sysctl -q -p /etc/sysctl.d/90-kiosk.conf

# ---------- enable ----------
step "enabling services"
systemctl daemon-reload
systemctl enable --now kiosk-screen.timer kiosk-restart.timer
systemctl restart zramswap.service || true
systemctl set-default multi-user.target >/dev/null
systemctl restart getty@tty1.service

step "done"
echo "Browser: $BROWSER   URL: $(. /etc/default/kiosk; echo "$KIOSK_URL")"
echo "Log:     /home/$KIOSK_USER/kiosk.log"
echo "Change settings in /etc/default/kiosk, then: sudo systemctl restart getty@tty1"
