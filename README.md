# huemdal

Turn a Philips Hue lamp into an **ON AIR sign**. huemdal is a macOS menu bar app that watches your camera's in-use state and changes a Hue lamp's color while you are in an online meeting, restoring the lamp's previous state when the meeting ends — so your family knows not to walk in.

## Features

- Detects when **any** app (Zoom, Google Meet, Teams, FaceTime, …) starts using **any** camera (built-in or external)
- Sets your chosen Hue lamp to an "ON AIR" color (default: red, 100% brightness)
- Restores the lamp to its pre-meeting state (on/off, color, brightness) when the camera turns off
- Debounces short camera flaps (e.g. Zoom's preview window) so the lamp doesn't flicker
- Recovers after a crash or restart: a leftover snapshot is restored on launch (unless a meeting is still in progress)
- Menu bar icon shows the current state: standby / ON AIR / error, with one-click reconnect on errors
- Optional launch at login

## Requirements

- macOS 14 (Sonoma) or later
- A Philips Hue Bridge (v2, square shape) on the same local network, with up-to-date firmware

## Install

Download the latest `Huemdal-<version>.zip` from [Releases](https://github.com/shinespark/huemdal/releases), unzip it, and move `Huemdal.app` to your Applications folder. Release builds are signed with a Developer ID and notarized by Apple, so they launch without any Gatekeeper workarounds.

## Setup

1. Launch huemdal — it appears in the menu bar
2. Open **Set Up…** from the menu
3. Search for your Hue Bridge and press the link button on the bridge when prompted
4. Choose the lamp to use as the ON AIR sign
5. Pick the ON AIR color and brightness, and use **Test Light** to verify

On macOS 15 and later, allow **Local Network** access when prompted; the app cannot reach the bridge without it.

## Privacy

- huemdal **never accesses camera video or microphone audio**. It only reads the system flag that says "some process is using this camera" (CoreMediaIO's `DeviceIsRunningSomewhere`), which is also why macOS shows no camera permission prompt.
- All communication stays on your local network, directly with your Hue Bridge over TLS (validated against the Signify root CA). Nothing is sent to any cloud service, with one exception: if mDNS discovery fails, the app queries `discovery.meethue.com` once to locate your bridge.
- The Hue application key is stored in the macOS Keychain.

## Building from source

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make build   # generate the Xcode project and build
make test    # run unit tests
make run     # build and launch the app
```

## Behavior details

- If you manually change the lamp during a meeting, the lamp is still restored to its **pre-meeting** snapshot when the meeting ends.
- If the bridge is unreachable, the app retries with exponential backoff and shows an error in the menu bar; camera monitoring continues.

See [docs/design.md](docs/design.md) (Japanese) for the full design.
