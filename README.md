# termux-flutter

Automated Flutter SDK installer for **Termux on Android aarch64**.
Build and debug Flutter apps directly on your phone.

## What it does

Android SDK/NDK tools ship as x86_64 Linux binaries. Termux runs on aarch64
Android. This script patches every x86_64 binary with a native equivalent so
Flutter can build APKs on-device without a computer.

**Replaces with native builds:**
- Dart SDK (Flutter's bundled Dart is glibc Linux, not Android)
- NDK clang toolchain ([HomuHomu833/android-ndk-custom](https://github.com/HomuHomu833/android-ndk-custom))
- aapt, aapt2, zipalign (via Termux packages)
- adb (via `android-tools` package)
- cmake, ninja (via Termux packages)

**Patches Flutter tools for Android host support:**
- `platform.dart` — treat Android as Linux
- `os.dart` — map `Abi.androidArm64` to `HostPlatform.linux_arm64`
- `android_sdk.dart` — fix NDK path resolution null check crash
- `flutter_cache.dart` — map artifact lookups to Linux

## Quick start

```bash
git clone https://github.com/Kaedo17/termux-flutter.git
cd termux-flutter
chmod +x install-flutter-termux.sh
./install-flutter-termux.sh
```

## Requirements

- [Termux](https://f-droid.org/en/packages/com.termux/) (F-Droid, NOT Google Play)
- ~8 GB free disk space
- Internet connection

## Documentation

- **[Setup guide](flutter-termux-setup.md)** — full manual installation with explanations

## Tested on

- Termux (aarch64, Android 14+)
- Flutter stable 3.44.8+, 3.47.2+
- NDK r28c

## Credits

- [HomuHomu833/android-sdk-custom](https://github.com/HomuHomu833/android-sdk-custom) — aarch64 NDK builds
- [lzhiyong/android-sdk-tools](https://github.com/lzhiyong/android-sdk-tools) — original inspiration

## License

MIT
