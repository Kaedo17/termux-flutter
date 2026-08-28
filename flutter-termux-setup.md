# Flutter on Termux (Android aarch64) - Complete Setup Guide

## Overview

This guide documents the full process of installing Flutter SDK on Termux
(running on an Android aarch64 device) so you can:

- Build Android APKs directly on your phone
- Debug apps via wireless ADB

The core challenge: Android SDK/NDK tools ship as x86_64 Linux binaries, but
Termux runs on aarch64 Android. Every binary that can't run natively must be
replaced with a native equivalent.

---

## Prerequisites

- Termux (latest from F-Droid, NOT Google Play)
- ~8 GB free disk space
- Internet connection

---

## Step 1: Install System Packages

```bash
pkg update && pkg upgrade -y
pkg install -y openjdk-17 which git curl unzip dart aapt aapt2 \
  android-tools ninja cmake build-essential
```

**Why each package:**
- `openjdk-17` - Java for Gradle/Android builds (provides JDK 25 runtime)
- `which` - needed by Flutter tools for binary lookup
- `dart` - native aarch64 Dart SDK (Flutter's bundled Dart is glibc/ARM64 Linux, not Android)
- `aapt`, `aapt2` - native Android asset packaging tools (SDK versions are x86_64)
- `android-tools` - native aarch64 ADB (SDK platform-tools are x86_64)
- `ninja`, `cmake` - native build tools (SDK versions are x86_64)
- `build-essential` - clang, make, etc.

---

## Step 2: Install Android SDK

### Download cmdline-tools

```bash
mkdir -p ~/android-sdk/cmdline-tools
curl -L -o ~/cmdline-tools.zip \
  "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
cd ~/android-sdk/cmdline-tools
unzip ~/cmdline-tools.zip
mv cmdline-tools latest
rm ~/cmdline-tools.zip
```

### Fix shebang for Termux

```bash
sed -i '1s|#!/usr/bin/env sh|#!/data/data/com.termux/files/usr/bin/env sh|' \
  ~/android-sdk/cmdline-tools/latest/bin/sdkmanager \
  ~/android-sdk/cmdline-tools/latest/bin/avdmanager
```

### Install SDK components

```bash
export ANDROID_HOME="$HOME/android-sdk"
export JAVA_HOME="/data/data/com.termux/files/usr"

yes | sdkmanager --sdk_root=$ANDROID_HOME \
  "platform-tools" "platforms;android-36" "build-tools;36.0.0"
```

### Replace x86_64 build-tools with native

```bash
BT=~/android-sdk/build-tools/36.0.0
for bin in aapt aapt2 zipalign; do
  rm -f "$BT/$bin"
  ln -sf "$(command -v $bin)" "$BT/$bin"
done
```

---

## Step 3: Install Flutter SDK

### Clone Flutter

```bash
git clone https://github.com/flutter/flutter.git -b stable --depth 1 ~/flutter
```

### Fix shebangs

```bash
termux-fix-shebang ~/flutter/bin/flutter ~/flutter/bin/dart
grep -rl '#!/usr/bin/env' ~/flutter/ 2>/dev/null | while read f; do
  termux-fix-shebang "$f" 2>/dev/null
done
```

### Replace Flutter's bundled Dart with native Termux Dart

Flutter downloads a glibc Linux Dart SDK that can't run on Android.
The native Termux Dart (android_arm64) works correctly.

> **Important:** You must run `flutter --version` first to trigger the Dart SDK download,
> then replace the binaries. This is done in the "Rebuild flutter_tools snapshot" step below.

### Rebuild flutter_tools snapshot

First, download the Dart SDK cache and initialize the flutter_tools dependencies:

```bash
export ANDROID_HOME="$HOME/android-sdk"
export JAVA_HOME="/data/data/com.termux/files/usr"
export PATH="$HOME/flutter/bin:$PATH"

# This downloads the Dart SDK and triggers initial setup
flutter --version 2>&1 || true

# Now the dart-sdk cache exists - replace the glibc Dart binary
mv ~/flutter/bin/cache/dart-sdk/bin/dart ~/flutter/bin/cache/dart-sdk/bin/dart.glibc.bak
ln -sf /data/data/com.termux/files/usr/bin/dart ~/flutter/bin/cache/dart-sdk/bin/dart
ln -sf /data/data/com.termux/files/usr/bin/dartaotruntime ~/flutter/bin/cache/dart-sdk/bin/dartaotruntime
ln -sf /data/data/com.termux/files/usr/bin/dartvm ~/flutter/bin/cache/dart-sdk/bin/dartvm

# Replace Dart snapshots
cd ~/flutter/bin/cache/dart-sdk/bin/snapshots
for f in *.snapshot; do
  termux_snap="/data/data/com.termux/files/usr/lib/dart-sdk/bin/snapshots/$f"
  if [ -f "$termux_snap" ]; then
    rm "$f"
    ln -sf "$termux_snap" "$f"
  fi
done

# Get flutter_tools dependencies and rebuild snapshot
cd ~/flutter/packages/flutter_tools && dart pub get
dart compile kernel \
  ~/flutter/packages/flutter_tools/bin/flutter_tools.dart \
  -o ~/flutter/bin/cache/flutter_tools.snapshot
```

---

## Step 4: Patch Flutter Platform Detection

Flutter doesn't officially support running ON Android. We patch it to
treat Android as Linux for host platform detection.

### Patch `platform.dart`

**File:** `~/flutter/packages/flutter_tools/lib/src/base/platform.dart`

```dart
// Change:
bool get isLinux => operatingSystem == 'linux';
// To:
bool get isLinux => operatingSystem == 'linux' || operatingSystem == 'android';

// Change:
bool get isAndroid => operatingSystem == 'android';
// To:
bool get isAndroid => false;
```

### Patch `flutter_cache.dart`

**File:** `~/flutter/packages/flutter_tools/lib/src/flutter_cache.dart`

In `getBinaryDirs()`, change the lookup to map `android` to `linux`:

```dart
// Change:
final List<String>? binaryDirs = artifacts[_platform.operatingSystem];
// To:
final String os = _platform.operatingSystem == 'android' ? 'linux' : _platform.operatingSystem;
final List<String>? binaryDirs = artifacts[os];
```

### Patch `os.dart` (host platform detection)

**File:** `~/flutter/packages/flutter_tools/lib/src/base/os.dart`

Flutter uses `Platform.version` to detect the host ABI. On Android/Termux this returns `android_arm64` which isn't mapped to any `HostPlatform`. Add Android ABI cases:

```dart
// Find the hostPlatform getter that returns switch (_currentAbi)
// Add before the default case:
//   Abi.androidArm64 => HostPlatform.linux_arm64,
//   Abi.androidArm => HostPlatform.linux_arm64,
//   Abi.androidX64 => HostPlatform.linux_x64,

// Full patched block:
HostPlatform get hostPlatform {
  return switch (_currentAbi) {
    Abi.macosX64 => HostPlatform.darwin_x64,
    Abi.macosArm64 => HostPlatform.darwin_arm64,
    Abi.linuxX64 => HostPlatform.linux_x64,
    Abi.linuxArm64 => HostPlatform.linux_arm64,
    Abi.linuxRiscv64 => HostPlatform.linux_riscv64,
    Abi.windowsX64 => HostPlatform.windows_x64,
    Abi.windowsArm64 => HostPlatform.windows_arm64,
    Abi.androidArm64 => HostPlatform.linux_arm64,
    Abi.androidArm => HostPlatform.linux_arm64,
    Abi.androidX64 => HostPlatform.linux_x64,
    _ => throw UnsupportedError('Unsupported host platform: $_currentAbi'),
  };
}
```

### Rebuild flutter_tools snapshot after patching

```bash
rm -f ~/flutter/bin/cache/flutter_tools.snapshot
dart compile kernel \
  ~/flutter/packages/flutter_tools/bin/flutter_tools.dart \
  -o ~/flutter/bin/cache/flutter_tools.snapshot
```

---

## Step 5: Install Native aarch64 NDK

The Android SDK installs x86_64 NDK tools. We replace the prebuilt
toolchain with a native aarch64 build.

### Download aarch64 NDK

```bash
curl -L -o ~/android-ndk-aarch64.tar.xz \
  "https://github.com/HomuHomu833/android-ndk-custom/releases/download/r28/android-ndk-r28c-aarch64-linux-android.tar.xz"
```

### Replace NDK prebuilt tools

```bash
NDK_PREBUILT=~/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt

# Backup original x86_64 prebuilt
mv "$NDK_PREBUILT/linux-x86_64" "$NDK_PREBUILT/linux-x86_64.bak"

# Extract aarch64 NDK
cd "$NDK_PREBUILT"
tar xf ~/android-ndk-aarch64.tar.xz
mv android-ndk-r28c/toolchains/llvm/prebuilt/linux-arm64 linux-x86_64
rm -rf android-ndk-r28c ~/android-ndk-aarch64.tar.xz
```

### Fix NDK toolchain host tag

The NDK's cmake toolchain only recognizes Linux/Darwin/Windows hosts.
Termux cmake detects the host as "Android", leaving `ANDROID_HOST_TAG` empty.

Create symlinks so empty host tag still resolves:

```bash
PREBUILT=~/android-sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt
for item in bin sysroot libexec; do
  [ -e "$PREBUILT/linux-x86_64/$item" ] && \
    ln -sfn "linux-x86_64/$item" "$PREBUILT/$item"
done
```

### Create cmake wrapper to inject host tag

```bash
CMAKE_BIN=~/android-sdk/cmake/3.22.1/bin/cmake
mv "$CMAKE_BIN" "$CMAKE_BIN.real"
cat > "$CMAKE_BIN" << 'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
args=("$@")
has_tag=false
for arg in "${args[@]}"; do
  [[ "$arg" == *ANDROID_HOST_TAG* ]] && has_tag=true
done
[ "$has_tag" = false ] && args+=("-DANDROID_HOST_TAG=linux-x86_64")
exec cmake "${args[@]}"
WRAPPER
chmod +x "$CMAKE_BIN"
```

### Replace SDK cmake/ninja with native versions

```bash
mv ~/android-sdk/cmake/3.22.1/bin/cmake ~/android-sdk/cmake/3.22.1/bin/cmake.linux
ln -sf /data/data/com.termux/files/usr/bin/cmake ~/android-sdk/cmake/3.22.1/bin/cmake

mv ~/android-sdk/cmake/3.22.1/bin/ninja ~/android-sdk/cmake/3.22.1/bin/ninja.linux
ln -sf /data/data/com.termux/files/usr/bin/ninja ~/android-sdk/cmake/3.22.1/bin/ninja
```

### Create impellerc stub

The `impellerc` shader compiler in `linux-arm64/` is a glibc Linux binary that can't run
on Android. Create a no-op stub that copies inputs to outputs (shaders will still be compiled
by the engine at runtime):

```bash
cat > ~/flutter/bin/cache/artifacts/engine/linux-arm64/impellerc << 'STUB'
#!/data/data/com.termux/files/usr/bin/bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sl) SL="$2"; shift 2 ;;
    --spirv) SPIRV="$2"; shift 2 ;;
    --input) INPUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$INPUT" && -n "$SL" ]]; then
  cp "$INPUT" "$SL" 2>/dev/null || touch "$SL"
fi
if [[ -n "$SL" && -n "$SPIRV" ]]; then
  cp "$SL" "$SPIRV" 2>/dev/null || touch "$SPIRV"
fi
exit 0
STUB
chmod +x ~/flutter/bin/cache/artifacts/engine/linux-arm64/impellerc
```

### Replace SDK ADB with native Termux ADB

The SDK's platform-tools ADB is x86_64. Replace it with the native Termux version:

```bash
rm -f ~/android-sdk/platform-tools/adb
ln -sf /data/data/com.termux/files/usr/bin/adb ~/android-sdk/platform-tools/adb
```

---

## Step 6: Configure Environment Variables

Add to `~/.bashrc`:

```bash
# Android SDK
export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/build-tools/36.0.0:$PATH"

# Flutter
export PATH="$HOME/flutter/bin:$PATH"

# Java
export JAVA_HOME="/data/data/com.termux/files/usr"
```

---

## Step 7: Configure Gradle

Create `~/.gradle/gradle.properties`:

```properties
org.gradle.jvmargs=-Xmx4g -XX:MaxMetaspaceSize=2g -Djava.net.preferIPv4Stack=true
android.useAndroidX=true
android.enableJetifier=true
systemProp.http.connectionTimeout=120000
systemProp.http.socketTimeout=120000
systemProp.https.connectionTimeout=120000
systemProp.https.socketTimeout=120000
systemProp.java.net.preferIPv4Stack=true
org.gradle.internal.http.connectionTimeout=120000
org.gradle.internal.http.socketTimeout=120000
org.gradle.daemon=true
org.gradle.parallel=true
android.aapt2FromMavenOverride=/data/data/com.termux/files/usr/bin/aapt2
```

> **Note:** `android.aapt2FromMavenOverride` is critical. Gradle downloads its own x86_64 `aapt2`
> from Maven which can't run on Android. This tells Gradle to use the native Termux `aapt2` instead.

---

## Step 8: Accept Android Licenses

```bash
yes | flutter doctor --android-licenses
```

---

## Step 9: Verify Installation

```bash
flutter doctor -v
```

Expected output:
```
[✓] Flutter (Channel stable, 3.44.8)
[✓] Android toolchain - develop for Android devices (Android SDK 36.0.0)
[✓] Connected device (1 available)
[✓] Network resources
```

---

## Wireless ADB Setup

### Enable on device

1. Go to **Settings > Developer Options**
2. Enable **Wireless Debugging**
3. Tap **Wireless Debugging** to open settings
4. Note the **IP address & Port** for pairing and connecting

### Pair (first time only)

```bash
adb pair localhost:<pairing-port>
# Enter the pairing code shown on screen
```

### Connect

```bash
adb connect localhost:<connect-port>
```

### Verify

```bash
adb devices
# Should show device as "device" (not "unauthorized")
```

### Install APK wirelessly

```bash
flutter install
# or
adb install ~/test_app/build/app/outputs/flutter-apk/app-debug.apk
```

### Debug wirelessly

```bash
cd ~/my_flutter_app
flutter run
```

---

## Step 10: Code OSS / VS Code Setup

Flutter SDK works in Code OSS but requires some extra configuration because
the extension host can't follow symlinks to Termux paths.

### Install Flutter & Dart extensions

```
ext install Dart-Code.flutter
ext install Dart-Code.dart-code
```

### Settings (real config location)

Code OSS on Termux reads settings from `~/.config/Code - OSS/User/settings.json`:

```json
{
    "dart.flutterSdkPath": "/data/data/com.termux/files/home/flutter",
    "dart.sdkPath": "/data/data/com.termux/files/usr/lib/dart-sdk",
    "dart.enableSdkFormatters": true,
    "flutter.activateAndroid": true,
    "terminal.integrated.env.linux": {
        "PATH": "/data/data/com.termux/files/home/flutter/bin:/data/data/com.termux/files/usr/bin:${env:PATH}",
        "ANDROID_HOME": "/data/data/com.termux/files/home/android-sdk",
        "ANDROID_SDK_ROOT": "/data/data/com.termux/files/home/android-sdk"
    }
}
```

### Environment variables for extension host

`terminal.integrated.env.linux` only affects the integrated terminal.
The Flutter extension daemon runs in the extension host process which
inherits env from when Code OSS was launched. To fix this, wrap the
Code OSS binary:

```bash
mv /data/data/com.termux/files/usr/bin/code-oss \
   /data/data/com.termux/files/usr/bin/code-oss.real

cat > /data/data/com.termux/files/usr/bin/code-oss << 'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
export ANDROID_HOME="$HOME/android-sdk"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$HOME/flutter/bin:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/build-tools/36.0.0:$ANDROID_HOME/platform-tools:$PATH"
exec /data/data/com.termux/files/usr/bin/code-oss.real "$@"
WRAPPER
chmod 755 /data/data/com.termux/files/usr/bin/code-oss
```

### Replace symlinks with wrapper scripts

Code OSS (Electron/Node.js) can't resolve symlinks to Termux paths.
Replace symlinks in `flutter/bin/cache/dart-sdk/bin/` with wrapper scripts:

```bash
DART_SDK_BIN=~/flutter/bin/cache/dart-sdk/bin

rm -f "$DART_SDK_BIN/dart"
cat > "$DART_SDK_BIN/dart" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec /data/data/com.termux/files/usr/lib/dart-sdk/bin/dart "$@"
EOF
chmod 755 "$DART_SDK_BIN/dart"

rm -f "$DART_SDK_BIN/dartaotruntime"
cat > "$DART_SDK_BIN/dartaotruntime" << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh
exec /data/data/com.termux/files/usr/lib/dart-sdk/bin/dartaotruntime "$@"
EOF
chmod 755 "$DART_SDK_BIN/dartaotruntime"
```

**Important:** Snapshot files in `bin/snapshots/` must be **actual copies**
(not wrapper scripts). They are ELF binaries read directly by dartaotruntime:

```bash
SNAPSHOTS_DIR=~/flutter/bin/cache/dart-sdk/bin/snapshots
TERMUX_SNAPSHOTS=/data/data/com.termux/files/usr/lib/dart-sdk/bin/snapshots
for f in "$TERMUX_SNAPSHOTS"/*; do
    fname=$(basename "$f")
    [ -f "$f" ] || continue
    rm -f "$SNAPSHOTS_DIR/$fname"
    cp "$f" "$SNAPSHOTS_DIR/$fname"
done
```

### Fix gradlew shebang for new projects

`flutter create` generates `gradlew` with `#!/usr/bin/env bash` which
doesn't exist in Termux. Patch the cached template:

```bash
sed -i '1s|#!/usr/bin/env bash|#!/data/data/com.termux/files/usr/bin/env bash|' \
  ~/flutter/bin/cache/artifacts/gradle_wrapper/gradlew
```

For existing projects, fix them individually:

```bash
sed -i '1s|#!/usr/bin/env bash|#!/data/data/com.termux/files/usr/bin/env bash|' \
  ~/your_project/android/gradlew
```

---

## Troubleshooting

### "Unsupported operating system: android"

The platform.dart patch wasn't applied. Rebuild flutter_tools.snapshot.

### "Unsupported host platform: android_arm64"

The os.dart patch wasn't applied. Flutter needs `Abi.androidArm64` mapped to `HostPlatform.linux_arm64`.
Patch `~/flutter/packages/flutter_tools/lib/src/base/os.dart` and rebuild flutter_tools.snapshot.

### "Snapshot not compatible with current VM configuration"

Dart snapshots are mismatched. Ensure all snapshots in
`~/flutter/bin/cache/dart-sdk/bin/snapshots/` are symlinked to Termux equivalents.

### Gradle DNS resolution fails

Ensure `~/.gradle/gradle.properties` has the IPv4 and timeout settings.

### cmake: "C compiler identification is unknown"

The cmake wrapper may not be injecting `ANDROID_HOST_TAG`. Check that
`~/android-sdk/cmake/3.22.1/bin/cmake` is the wrapper script (not `.real`).

### aapt2 daemon startup failed

Ensure `~/android-sdk/build-tools/36.0.0/aapt2` points to Termux's native aapt2.

### "INSTALL_FAILED_USER_RESTRICTED" when running

The device requires USB install permission. Either:
- Accept the install prompt on the device, or
- Use `adb install -r -d` to force-replace

### "The file or directory could not be found" (impellerc)

The `impellerc` shader compiler is a glibc binary. Create the stub wrapper
described in Step 5.

### "Could not find Dart in your Flutter SDK" (Code OSS)

The extension can't resolve symlinks. Replace symlinks with wrapper scripts
as described in Step 10.

### "The file or directory could not be found" (gradlew)

The `gradlew` shebang is `#!/usr/bin/env bash` which doesn't exist in Termux.
Patch it as described in Step 10 ("Fix gradlew shebang").

### Device not showing in Code OSS

The Flutter extension daemon runs without `ANDROID_HOME` because the
extension host process doesn't inherit `.bashrc` env vars. Apply the
Code OSS wrapper from Step 10.

### "Bad ELF magic" on frontend_server_aot.dart.snapshot

Snapshot files were replaced with wrapper scripts instead of actual copies.
Restore them with the copy command in Step 10.

---

## File Layout

```
~/flutter/                          Flutter SDK
~/flutter/bin/cache/dart-sdk/bin/dart (wrapper script -> Termux dart)
~/flutter/bin/cache/dart-sdk/bin/dartaotruntime (wrapper script -> Termux dartaotruntime)
~/flutter/bin/cache/dart-sdk/bin/snapshots/*.snapshot (copies of Termux snapshots)
~/flutter/bin/cache/flutter_tools.snapshot (compiled with native dart)
~/flutter/bin/cache/artifacts/engine/linux-arm64/impellerc (stub wrapper)
~/flutter/bin/cache/artifacts/gradle_wrapper/gradlew (patched shebang)

~/android-sdk/
  cmdline-tools/latest/bin/sdkmanager
  platforms/android-36/
  build-tools/36.0.0/
    aapt -> /data/.../usr/bin/aapt (symlinked)
    aapt2 -> /data/.../usr/bin/aapt2 (symlinked)
  platform-tools/
    adb -> /data/.../usr/bin/adb (symlinked)
  cmake/3.22.1/bin/cmake (wrapper script injecting ANDROID_HOST_TAG)
  cmake/3.22.1/bin/ninja -> /data/.../usr/bin/ninja (symlinked)
  ndk/28.2.13676358/toolchains/llvm/prebuilt/linux-x86_64/
    bin/clang -> clang-19 (aarch64 NDK build from HomuHomu833)
    sysroot/

~/.gradle/
  gradle.properties (includes android.aapt2FromMavenOverride)
  caches/.../transforms/ (aapt2 replaced in JAR)

/data/data/com.termux/files/usr/bin/code-oss (wrapper -> code-oss.real)
/data/data/com.termux/files/usr/bin/code-oss.real (original Code OSS binary)
~/.config/Code - OSS/User/settings.json (Flutter SDK paths)
```
