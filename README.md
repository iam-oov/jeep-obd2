# Jeep OBD2

Android app (Flutter) that reads and clears diagnostic trouble codes (DTC) through an ELM327 Bluetooth adapter, shows live sensor readings, and finds YouTube repair videos for each code.

Tested with a 1998 Jeep Wrangler TJ (ISO 9141-2) and a Bluetooth Classic ELM327 clone that cannot be paired from the phone's Settings app.

> The app's interface is in Spanish. Code comments, documentation and release notes are in English.

## Features

- Connects to ELM327 adapters over Bluetooth Classic (RFCOMM socket, no pairing required) or Bluetooth LE.
- Reads stored (mode 03) and pending (mode 07) codes, with Spanish descriptions.
- Clears codes (mode 04), with confirmation.
- Live readings: battery voltage, coolant temperature, RPM, speed and any other PID the vehicle supports.
- Multiple saved vehicles; reads the VIN (mode 09) when the vehicle provides it, and decodes it with the NHTSA vPIC API.
- Repair video search: Claude Haiku proposes searches and picks the best videos; results come from the YouTube Data API.
- Log screen with every command sent and every raw reply, for debugging.

## Install

Download the APK from [Releases](../../releases) and install it on an Android device (version 7 or newer).

The released APK contains **no API keys**. For video search, open **⋮ → Llaves de API** (or search for a video the first time) and enter:

- **Anthropic key** — from console.anthropic.com → API Keys.
- **YouTube key** — from Google Cloud: enable *YouTube Data API v3*, then create an API key under Credentials.

The app tests both keys before saving them. They are stored encrypted on the device (Android Keystore) and never leave it except in requests to those two services.

## Build

Requirements: Flutter (stable) and the Android SDK.

```
flutter build apk --release
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

Optional, for your own device only: copy `secrets.example.json` to `secrets.json`, fill in the two keys, and build with `--dart-define-from-file=secrets.json` so the app starts with them. `secrets.json` is git-ignored. An APK built this way contains your keys — do not publish it.

## Tests

```
flutter test
```

Tests use a simulated ELM327 (`test/fake_elm.dart`) and simulated replies from Claude, YouTube and NHTSA. No hardware or API keys are needed.

## Project layout

- `lib/bluetooth/` — adapter transports (Bluetooth Classic via `SppBridge.kt`, BLE via flutter_blue_plus) and the ELM327 command queue.
- `lib/obd/` — ISO 9141-2 / CAN protocol handling, DTC and VIN decoding, live data.
- `lib/vehicle/` — vehicle model, garage storage, NHTSA catalog.
- `lib/solutions/` — Claude and YouTube clients, video finder, API key storage.
- `lib/ui/` — screens and dialogs.
- `android/app/src/main/kotlin/.../SppBridge.kt` — native RFCOMM socket channel.
