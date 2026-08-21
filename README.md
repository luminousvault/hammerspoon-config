# Hammerspoon Config

[![License](https://img.shields.io/github/license/luminousvault/hammerspoon-config)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS-000000?logo=apple&logoColor=white)](https://www.hammerspoon.org/)
[![Lua](https://img.shields.io/badge/Lua-5.4-2C2D72?logo=lua&logoColor=white)](https://www.lua.org/)

**English** | [한국어](README.ko.md)

Personal configuration for [Hammerspoon](https://www.hammerspoon.org/), the macOS automation tool.

## Features

| Module | Description |
|--------|-------------|
| [`modules/input_source.lua`](modules/input_source.lua) | **Toggle Korean/English input with a solo tap of the right Command key.** Combined with other keys it still works as a normal Command key. Rolling into the next character before releasing Command no longer fires shortcuts — it switches first, then types the key in the new input source (allowlisted keys like `,` are exempt). Shows a `[한] 두벌식` / `[A] ABC` alert at the bottom of the focused screen on switch (modes: all / manual / off) |
| [`modules/audio_by_location.lua`](modules/audio_by_location.lua) | **Auto-switch audio output state based on Wi-Fi SSID.** Define any number of places in `local_config.lua`, each with its own policy: fixed state or remember-and-restore (`remember`), speaker-only enforcement that leaves Bluetooth earbuds and other personal devices alone (`speakerOnly`), re-apply on wake (`enforceOnWake`), and a default place for unregistered SSIDs (`fallback`) |
| [`modules/caps_lock.lua`](modules/caps_lock.lua) | **CAPS LOCK toggle alert.** `[⇪] ABC` with an orange badge for 2s when engaged, `[⇪] abc` in gray for 0.6s when released. Shown only while the English input source is active. Follows input_source's alert mode (hidden when `off`) |
| [`modules/bluetooth_device.lua`](modules/bluetooth_device.lua) | **Bluetooth device hotkey toggle + auto-reconnect on return.** Define devices (MAC + hotkey) in `local_config.lua`. Detects away→return via input idle time (works whether or not the screen was locked), and if a device you were using before leaving is disconnected, tries to reconnect once — failures are silent, only success shows an alert. Requires `blueutil` (`brew install blueutil`) |
| [`modules/alert.lua`](modules/alert.lua) | **Shared alert UI** replacing `hs.alert`. Configurable position (TOP / CENTER / BOTTOM) and duration (SHORT / NORMAL / LONG), with optional badge (a character or an icon) |

## Installation

```bash
git clone <repo-url> ~/.hammerspoon
cd ~/.hammerspoon
cp local_config.example.lua local_config.lua   # define your places and SSIDs
```

1. Install Hammerspoon: `brew install --cask hammerspoon`
2. Define your places (SSIDs + audio policies) in `local_config.lua`
3. Launch Hammerspoon and grant permissions:
   - **Accessibility** (System Settings → Privacy & Security): required for key event taps (`eventtap`)
   - **Location Services**: required to read the SSID on macOS Sonoma and later (otherwise the SSID is always nil)

## Usage

- Reload config: `⌘⌥⌃R` (or menu bar icon → Reload Config)
- Terminal integration (`hs` CLI) is enabled via `require("hs.ipc")`

### Console commands

From the Hammerspoon console or `hs -c "..."` in a terminal:

```lua
inputSource.status()             -- check the input source watcher state
inputSource.setAlertMode("all")  -- alert mode: "all" / "manual" / "off"
inputSource.previewAlert()       -- preview the alert design

audioLoc.status()                -- show SSID, place, output device, mute state
audioLoc.reapply()               -- re-apply the current place policy now
audioLoc.pin()                   -- save the current state for this place (remembering places only)
audioLoc.reset()                 -- clear remembered states

btDevice.status()                -- show Bluetooth device connection / in-use state
btDevice.toggle("openfit")       -- toggle a device connection (same as the hotkey)

customAlert.show("message")      -- call the shared alert directly
```

## Testing

```bash
./tests/run.sh
```

Integration tests run inside the live Hammerspoon runtime — alerts appear on screen and audio state is briefly touched (then restored), so run them when you're not in a meeting. Tests whose preconditions don't match the current environment (unregistered SSID, no Bluetooth device, …) are reported as SKIP.

To add a suite, just drop a `tests/test_<feature>.lua` file returning `{ { name = ..., fn = function(t) ... end }, ... }` — files are auto-discovered, no runner changes needed. Helpers available on `t`: `sleep`, `waitUntil`, `eq`, `truthy`, `skip`.

## Layout

```
~/.hammerspoon/
├── init.lua                    # entry point: loads modules, reload hotkey
├── local_config.lua            # machine-local settings (SSIDs etc., not committed)
├── local_config.example.lua    # template for local_config
└── modules/
    ├── alert.lua               # shared alert UI
    ├── input_source.lua        # Korean/English toggle + switch alert
    └── audio_by_location.lua   # location-based audio switching
```
