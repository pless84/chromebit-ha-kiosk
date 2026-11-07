Put the Chromebit's Wi-Fi firmware here, copied from its ChromeOS `/lib/firmware/brcm/`:

- `brcmfmac4354-sdio.txt` (required: board-specific Wi-Fi settings)
- `brcmfmac4354-sdio.bin` (required; used only if Debian's `firmware-brcm80211` lacks it)
- `BCM4354.hcd` (optional, Bluetooth)

These files aren't in the repo because they aren't freely licensed. See step 2 in the main README.
