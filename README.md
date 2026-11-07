# Chromebit Home Assistant kiosk

Turn an old **ASUS Chromebit CS10** (the HDMI stick, `veyron_mickey`, RK3288, 2 GB) into a wall-mounted
**Home Assistant touchscreen**: plug it into an HDMI monitor with USB touch, and it boots straight into a
full-screen dashboard, logged in, with no browser bars and no mouse cursor.

ChromeOS stopped getting updates for the Chromebit in 2020, and its browser is too old for today's Home
Assistant frontend. These scripts replace ChromeOS with **Debian 13 (armhf)**, then run Chromium in a
tiny Wayland kiosk compositor ([cage](https://github.com/cage-kiosk/cage)).

What you get:

- Debian 13 on the internal eMMC, booted by the stock ChromeOS firmware in developer mode
  (no firmware flashing, no write-protect screw).
- Autologin → `cage` → Chromium full screen on your HA dashboard, restarted if it crashes, and once a night.
- Dark mode, hidden mouse cursor, touch input (any USB HID touchscreen).
- Screen off at night on a schedule (default 23:00–07:00).
- zram swap tuned so HA's frontend runs comfortably in 2 GB.
- An example touch dashboard sized for 1920×1080 (`examples/wall-dashboard.json`).

Tested on one CS10 with a 1920×1080 HDMI touch monitor (USB touch reported as "TSTP MTouch").

## Files

| File | Runs on | What it does |
|---|---|---|
| `build-usb.sh` | Linux PC (sudo) | Builds a bootable Debian 13 USB stick for the Chromebit. |
| `install-emmc.sh` | Chromebit, booted from the stick | Copies Debian to the internal eMMC (erases ChromeOS). |
| `kiosk-setup.sh` | Chromebit | Installs and configures the kiosk. Safe to re-run. |
| `fix-root-uuid.sh` | Linux PC | Only for sticks built by old versions of `build-usb.sh`. |
| `examples/wall-dashboard.json` | Home Assistant | Example dashboard (replace the entity IDs with yours). |
| `firmware/` | – | **You supply this:** Wi-Fi firmware copied from the Chromebit's ChromeOS (see step 2). |

## What you need

- ASUS Chromebit CS10, its power supply, an HDMI touch monitor (or any HDMI screen; touch is optional).
- A **USB hub** and a USB keyboard for the setup (the Chromebit has one USB port).
- A USB stick, 2–64 GB (it gets erased).
- A Linux PC to build the stick. On Fedora:
  ```bash
  sudo dnf install debootstrap qemu-user-static vboot-utils uboot-tools python3 rsync
  ```
  (Debian/Ubuntu: `debootstrap qemu-user-static binfmt-support vboot-kernel-utils cgpt u-boot-tools python3-venv rsync`.)

## Setup

### 1. Developer mode and USB boot

1. Put the Chromebit in developer mode: unplug power, hold a paperclip in the recovery pinhole, plug power
   back in, release at the recovery screen, press **Ctrl+D**, then press the pinhole once more to confirm.
   It wipes itself and reboots to an **"OS verification is OFF"** screen (it shows this on every boot from now on).
2. Turn on USB boot. At the ChromeOS setup screen press **Ctrl+Alt+F2** (or **Ctrl+Alt+→** on a Chrome keyboard),
   log in as `root`, and run:
   ```bash
   crossystem dev_boot_usb=1
   crossystem dev_boot_usb    # should print 1
   ```
   Without this, Ctrl+U at boot does nothing and the Chromebit just starts ChromeOS.

### 2. Copy the Wi-Fi firmware out of ChromeOS

Debian doesn't ship the Chromebit's Wi-Fi settings file. From the same root console, copy these from
`/lib/firmware/brcm/` (and `/lib/firmware/brcm/BCM4354*.hcd` for Bluetooth, optional) to a USB stick, then into
`firmware/` in this repo:

```
firmware/brcmfmac4354-sdio.txt
firmware/brcmfmac4354-sdio.bin
```

They're not in this repo because they aren't freely licensed. Do this **before** step 4, which erases ChromeOS.

### 3. Build and boot the USB stick

```bash
sudo KBD_LAYOUT=us REGDOM=US ./build-usb.sh /dev/sdX
```

Set `KBD_LAYOUT` (console keyboard) and `REGDOM` (your Wi-Fi country code). Or put them in a
`local.env` file next to the script. The script asks for a login password and your Wi-Fi name and password.
Your `~/.ssh/*.pub` keys are added, so you can SSH in. The first build takes 10–20 minutes (it runs an ARM
system under emulation). Later builds are cached.

Plug the stick and keyboard into the Chromebit through the hub, power on, and press **Ctrl+U** at
"OS verification is OFF". The console shows the Chromebit's IP address above the login prompt.

### 4. Install to the internal eMMC

The touchscreen needs the only USB port, so Debian has to live on the eMMC:

```bash
scp install-emmc.sh /var/tmp/chromebit-build/kernel.img <user>@<chromebit-ip>:
ssh -t <user>@<chromebit-ip> sudo bash install-emmc.sh kernel.img
```

Type `ERASE` when asked. Then power off, **remove the stick** (the stick and the eMMC share a filesystem UUID,
so never boot with both), plug in the touchscreen's USB cable, and power on. At "OS verification is OFF" press
**Ctrl+D**, or wait 30 seconds.

### 5. Kiosk

```bash
ssh <user>@<chromebit-ip> 'sudo KIOSK_URL=http://homeassistant.local:8123/ TIMEZONE=Europe/Berlin bash -s' < kiosk-setup.sh
```

It installs cage, Chromium and Mesa (the Mali GPU works with the open `panfrost` driver), creates a locked
`kiosk` user with autologin, and starts the browser. Settings end up in `/etc/default/kiosk` on the Chromebit:

```bash
KIOSK_URL="http://homeassistant.local:8123/"
SCREEN_OFF="23:00"     # both empty = always on
SCREEN_ON="07:00"
KIOSK_EXTRA_FLAGS=""   # e.g. "--disable-gpu" if you see glitches
```

Apply changes with `sudo systemctl restart getty@tty1`.

### 6. Home Assistant: log in without a password

Give the Chromebit a fixed IP (a DHCP reservation in your router). Create a **non-admin** HA user for it
(Settings → People → Add person → Allow login), and find its user ID: Developer tools → Template →
`{{ state_attr('person.<name>', 'user_id') }}`. Then add to `configuration.yaml`:

```yaml
homeassistant:
  auth_providers:
    - type: trusted_networks          # must be first, or the login page still shows
      trusted_networks:
        - 192.168.1.50/32             # the Chromebit only
      trusted_users:
        192.168.1.50: <user id>
      allow_bypass_login: true
    - type: homeassistant             # keep this: everyone else logs in as before
```

Check the config and restart HA. Other devices never see the trusted-network option, so they still get the
normal login page. If your HA sits behind a reverse proxy, read HA's
[trusted networks docs](https://www.home-assistant.io/docs/authentication/providers/#trusted-networks) first.

### 7. Dashboard (optional)

`examples/wall-dashboard.json` is a sections dashboard laid out for a 1920×1080 landscape screen: a clock,
weather, lights with brightness sliders, scene buttons, music, a calendar, a shopping list and laundry status.
In HA, create a dashboard (Settings → Dashboards → Add), open it, choose Edit → ⋮ → Raw configuration editor,
paste the file, and replace the entity IDs with yours. Point `KIOSK_URL` at it, e.g.
`http://homeassistant.local:8123/dashboard-wall/home`.

To hide HA's sidebar on the kiosk: on the touchscreen, tap ☰ → your user (bottom left) → turn on
**Always hide the sidebar**. It's stored in the kiosk browser's profile, so it survives reboots.

## How the kiosk works

| Piece | Where |
|---|---|
| Autologin on tty1 as `kiosk` | `/etc/systemd/system/getty@tty1.service.d/autologin.conf` |
| cage + browser restart loop | `/home/kiosk/.bash_profile` → `/usr/local/bin/kiosk-browser` |
| Dark mode | Chromium `--force-dark-mode` (HA's default theme follows it) |
| Hidden cursor | Transparent cursor theme in `/usr/share/icons/invisible`, set as the kiosk user's default theme. A udev rule makes libinput ignore the HDMI CEC input (`dw_hdmi`), which otherwise shows up as a mouse. |
| Night screen-off | `kiosk-screen.timer` (every 5 min) → `/usr/local/bin/kiosk-screen auto` (`wlopm`, fallback `wlr-randr`) |
| Daily browser restart | `kiosk-restart.timer`, 04:00 |
| Browser log | `/home/kiosk/kiosk.log` |

Get the console back: SSH in and run `sudo systemctl stop getty@tty1` (`start` to resume).
Test the screen schedule: `sudo kiosk-screen off` / `sudo kiosk-screen on`.

## Known quirks

**USB boot off.** If Ctrl+U does nothing, USB boot isn't enabled (step 1.2). On this firmware
`dev_default_boot=usb` is ignored, so booting the stick always needs Ctrl+U.

**Write-protected eMMC start.** On the unit this was built on, the first 4 MiB of the eMMC (blocks 0–8191) are
*permanently* write-protected, and the primary GPT header there reads `IGNOREME`. Check yours (from Debian on the stick):

```bash
sudo apt install mmc-utils
sudo mmc writeprotect user get /dev/mmcblk0
```

ChromeOS's firmware handles this by using only the backup GPT at the end of the disk, and
`install-emmc.sh` does the same. It writes only the backup GPT and starts the partitions at sector 8192.
For this to work, the kernel command line includes `gpt`, which makes Linux accept a backup-only GPT;
`build-usb.sh` adds it. On a normal eMMC, `install-emmc.sh` writes both GPT copies. That path hasn't been
tested on real hardware yet, so reports are welcome.

**Kernel image size.** The Chromebit's firmware loads at most 16 MiB, so the initramfs is kept small
(`MODULES=list`, zstd). `build-usb.sh` checks the size.

**Developer-mode boot screen.** "OS verification is OFF" shows for 30 seconds on every boot, then boots the
eMMC. Removing it means changing firmware (GBB) flags, which needs the hardware write-protect disabled, so
it isn't covered here.

## License

MIT. See [LICENSE](LICENSE). Not affiliated with ASUS, Google or Home Assistant.
