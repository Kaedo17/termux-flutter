#!/data/data/com.termux/files/usr/bin/bash
#
# install-flutter-termux.sh
#
# Automated Flutter SDK installer for Termux on Android (aarch64).
# Builds Android APKs natively on-device and supports wireless ADB debugging.
#
# Usage:
#   chmod +x install-flutter-termux.sh
#   ./install-flutter-termux.sh
#
# Tested on: Termux (aarch64, Android 14+)
# Requires: ~8GB free disk, internet connection
#
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────
ANDROID_SDK_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"
NDK_URL="https://github.com/HomuHomu833/android-ndk-custom/releases/download/r28/android-ndk-r28c-aarch64-linux-android.tar.xz"
FLUTTER_BRANCH="stable"
ANDROID_PLATFORM="android-36"
BUILD_TOOLS="36.0.0"
CMAKE_VERSION="3.22.1"
NDK_VERSION="28.2.13676358"

SDK_ROOT="$HOME/android-sdk"
FLUTTER_ROOT="$HOME/flutter"
BASHRC="$HOME/.bashrc"

# ─── Colors ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step() { echo -e "\n${BLUE}═══ Step $1: $2 ═══${NC}"; }

# ─── Preflight checks ───────────────────────────────────────────────
preflight() {
    if [ ! -d "$HOME/.termux" ] && [ ! -f "$PREFIX/bin/pkg" ]; then
        err "This script must run inside Termux."
        exit 1
    fi
    local free_kb
    free_kb=$(df "$HOME" | awk 'NR==2{print $4}')
    if [ "$free_kb" -lt 8000000 ]; then
        warn "Less than 8GB free disk space. Installation may fail."
    fi
    command -v curl >/dev/null || { err "curl not found"; exit 1; }
    command -v git  >/dev/null || { err "git not found";  exit 1; }
}

# ─── Step 1: System packages ────────────────────────────────────────
install_system_packages() {
    step 1 "System packages"
    pkg update -y
    pkg install -y openjdk-17 which git curl unzip dart aapt aapt2 \
        android-tools ninja cmake build-essential termux-properties
    log "System packages installed."
}

# ─── Step 2: Android SDK ────────────────────────────────────────────
install_android_sdk() {
    step 2 "Android SDK"
    mkdir -p "$SDK_ROOT/cmdline-tools"

    if [ ! -f "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" ]; then
        log "Downloading cmdline-tools..."
        curl -L -o /tmp/cmdline-tools.zip "$ANDROID_SDK_URL"
        cd "$SDK_ROOT/cmdline-tools"
        unzip -q /tmp/cmdline-tools.zip
        mv cmdline-tools latest
        rm /tmp/cmdline-tools.zip
    fi

    # Fix shebang
    sed -i '1s|#!/usr/bin/env sh|#!/data/data/com.termux/files/usr/bin/env sh|' \
        "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
        "$SDK_ROOT/cmdline-tools/latest/bin/avdmanager" 2>/dev/null || true

    export ANDROID_HOME="$SDK_ROOT"
    export JAVA_HOME="/data/data/com.termux/files/usr"

    log "Installing SDK components..."
    yes | "$SDK_ROOT/cmdline-tools/latest/bin/sdkmanager" \
        --sdk_root="$SDK_ROOT" \
        "platform-tools" "platforms;$ANDROID_PLATFORM" "build-tools;$BUILD_TOOLS" 2>&1 | tail -5

    # Replace x86_64 build-tools with native
    local BT="$SDK_ROOT/build-tools/$BUILD_TOOLS"
    for bin in aapt aapt2 zipalign; do
        rm -f "$BT/$bin"
        ln -sf "$(command -v $bin)" "$BT/$bin"
    done
    log "Android SDK installed."
}

# ─── Step 3: Flutter SDK ────────────────────────────────────────────
install_flutter() {
    step 3 "Flutter SDK"

    if [ ! -d "$FLUTTER_ROOT" ]; then
        log "Cloning Flutter (this takes a few minutes)..."
        git clone "https://github.com/flutter/flutter.git" \
            -b "$FLUTTER_BRANCH" --depth 1 "$FLUTTER_ROOT"
    fi

    # Fix all shebangs
    log "Fixing shebangs..."
    find "$FLUTTER_ROOT" -type f -name "*.sh" -o -name "flutter" -o -name "dart" 2>/dev/null | \
        while read f; do termux-fix-shebang "$f" 2>/dev/null; done

    # Replace bundled Dart with native Termux Dart
    log "Replacing Dart SDK with native Termux Dart..."
    local DART_SDK="$FLUTTER_ROOT/bin/cache/dart-sdk"

    mv "$DART_SDK/bin/dart" "$DART_SDK/bin/dart.glibc.bak" 2>/dev/null || true
    ln -sf /data/data/com.termux/files/usr/bin/dart "$DART_SDK/bin/dart"
    ln -sf /data/data/com.termux/files/usr/bin/dartaotruntime "$DART_SDK/bin/dartaotruntime" 2>/dev/null || true
    ln -sf /data/data/com.termux/files/usr/bin/dartvm "$DART_SDK/bin/dartvm" 2>/dev/null || true

    # Replace snapshots with Android-compatible ones
    log "Replacing Dart snapshots..."
    local SNAPSHOTS="$DART_SDK/bin/snapshots"
    local TERMUX_SNAPS="/data/data/com.termux/files/usr/lib/dart-sdk/bin/snapshots"
    mkdir -p "$SNAPSHOTS"
    for f in "$TERMUX_SNAPS"/*.snapshot; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f")
        rm -f "$SNAPSHOTS/$name"
        ln -sf "$f" "$SNAPSHOTS/$name"
    done

    log "Building flutter_tools snapshot..."
    rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
    dart compile kernel \
        "$FLUTTER_ROOT/packages/flutter_tools/bin/flutter_tools.dart" \
        -o "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
    log "Flutter SDK installed."
}

# ─── Step 4: Patch Flutter platform detection ────────────────────────
patch_flutter_platform() {
    step 4 "Platform patches"

    local PLATFORM_DART="$FLUTTER_ROOT/packages/flutter_tools/lib/src/base/platform.dart"
    local CACHE_DART="$FLUTTER_ROOT/packages/flutter_tools/lib/src/flutter_cache.dart"

    # Patch platform.dart - make isLinux return true for Android
    if ! grep -q "operatingSystem == 'android'" "$PLATFORM_DART" | head -1; then
        sed -i "s|bool get isLinux => operatingSystem == 'linux';|bool get isLinux => operatingSystem == 'linux' || operatingSystem == 'android';|" "$PLATFORM_DART"
        sed -i "s|bool get isAndroid => operatingSystem == 'android';|bool get isAndroid => false;|" "$PLATFORM_DART"
    fi

    # Patch flutter_cache.dart - map android to linux for artifact lookup
    if ! grep -q "operatingSystem == 'android'" "$CACHE_DART" 2>/dev/null; then
        sed -i "s|final List<String>? binaryDirs = artifacts\[_platform.operatingSystem\];|final String os = _platform.operatingSystem == 'android' ? 'linux' : _platform.operatingSystem; final List<String>? binaryDirs = artifacts[os];|" "$CACHE_DART"
    fi

    log "Rebuilding flutter_tools snapshot..."
    rm -f "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
    dart compile kernel \
        "$FLUTTER_ROOT/packages/flutter_tools/bin/flutter_tools.dart" \
        -o "$FLUTTER_ROOT/bin/cache/flutter_tools.snapshot"
    log "Platform patches applied."
}

# ─── Step 5: Native NDK ─────────────────────────────────────────────
install_native_ndk() {
    step 5 "Native aarch64 NDK"
    local NDK_DIR="$SDK_ROOT/ndk/$NDK_VERSION"
    local PREBUILT="$NDK_DIR/toolchains/llvm/prebuilt"

    if [ ! -d "$PREBUILT/linux-x86_64/bin" ]; then
        warn "NDK prebuilt dir not found at $PREBUILT"
        warn "SDK may have installed a different NDK version."
        warn "Run: ls $SDK_ROOT/ndk/ to check, then update NDK_VERSION in this script."
        return 0
    fi

    # Check if already aarch64
    if "$PREBUILT/linux-x86_64/bin/clang" --version 2>/dev/null | grep -q "aarch64"; then
        log "NDK already uses aarch64 clang."
    else
        log "Downloading aarch64 NDK..."
        curl -L -o /tmp/ndk-aarch64.tar.xz "$NDK_URL"

        log "Replacing NDK prebuilt tools..."
        mv "$PREBUILT/linux-x86_64" "$PREBUILT/linux-x86_64.bak"
        cd "$PREBUILT"
        tar xf /tmp/ndk-aarch64.tar.xz
        mv android-ndk-r28c/toolchains/llvm/prebuilt/linux-arm64 linux-x86_64
        rm -rf android-ndk-r28c /tmp/ndk-aarch64.tar.xz
    fi

    # Fix host tag: create symlinks for empty ANDROID_HOST_TAG
    for item in bin sysroot libexec; do
        [ -e "$PREBUILT/linux-x86_64/$item" ] && \
            ln -sfn "linux-x86_64/$item" "$PREBUILT/$item"
    done

    log "NDK setup complete."
}

# ─── Step 6: cmake/ninja fixes ──────────────────────────────────────
fix_cmake_ninja() {
    step 6 "cmake/ninja"
    local CMAKE_BIN="$SDK_ROOT/cmake/$CMAKE_VERSION/bin"

    if [ ! -f "$CMAKE_BIN/cmake" ] && [ ! -f "$CMAKE_BIN/cmake.real" ]; then
        warn "cmake not found at $CMAKE_BIN. Skipping."
        return 0
    fi

    # Replace cmake binary with native Termux version
    if [ -f "$CMAKE_BIN/cmake" ] && readelf -l "$CMAKE_BIN/cmake" 2>/dev/null | grep -q "ld-linux-x86-64"; then
        mv "$CMAKE_BIN/cmake" "$CMAKE_BIN/cmake.sdk-x86_64"
        ln -sf "$(command -v cmake)" "$CMAKE_BIN/cmake"
    fi

    # Replace ninja with native version
    if [ -f "$CMAKE_BIN/ninja" ] && readelf -l "$CMAKE_BIN/ninja" 2>/dev/null | grep -q "ld-linux-x86-64"; then
        mv "$CMAKE_BIN/ninja" "$CMAKE_BIN/ninja.sdk-x86_64"
        ln -sf "$(command -v ninja)" "$CMAKE_BIN/ninja"
    fi

    # Create cmake wrapper that injects ANDROID_HOST_TAG
    local CMAKE_TARGET="$CMAKE_BIN/cmake"
    if [ -x "$CMAKE_TARGET" ] || [ -L "$CMAKE_TARGET" ]; then
        # Only create wrapper if not already a wrapper
        if ! head -1 "$CMAKE_TARGET" 2>/dev/null | grep -q "ANDROID_HOST_TAG"; then
            mv "$CMAKE_TARGET" "$CMAKE_TARGET.real"
            cat > "$CMAKE_TARGET" << 'WRAPPER'
#!/data/data/com.termux/files/usr/bin/bash
args=("$@")
has_tag=false
for arg in "${args[@]}"; do
    [[ "$arg" == *ANDROID_HOST_TAG* ]] && has_tag=true
done
[ "$has_tag" = false ] && args+=("-DANDROID_HOST_TAG=linux-x86_64")
exec cmake "${args[@]}"
WRAPPER
            chmod +x "$CMAKE_TARGET"
        fi
    fi

    log "cmake/ninja configured."
}

# ─── Step 7: Environment variables ──────────────────────────────────
setup_environment() {
    step 7 "Environment variables"

    local MARKER="# Flutter/Android SDK (auto-installed)"
    # Remove old entries if present
    sed -i "/$MARKER/,/^$/d" "$BASHRC" 2>/dev/null || true

    cat >> "$BASHRC" << EOF

$MARKER
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_SDK_ROOT="\$ANDROID_HOME"
export PATH="\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/build-tools/$BUILD_TOOLS:\$PATH"
export PATH="$FLUTTER_ROOT/bin:\$PATH"
export JAVA_HOME="/data/data/com.termux/files/usr"
$MARKER
EOF

    log "Environment variables added to .bashrc."
}

# ─── Step 8: Gradle configuration ───────────────────────────────────
setup_gradle() {
    step 8 "Gradle configuration"
    mkdir -p "$HOME/.gradle"
    cat > "$HOME/.gradle/gradle.properties" << 'EOF'
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
EOF
    log "Gradle configured."
}

# ─── Step 9: Accept licenses & verify ───────────────────────────────
verify_installation() {
    step 9 "Verify installation"
    export ANDROID_HOME="$SDK_ROOT"
    export JAVA_HOME="/data/data/com.termux/files/usr"
    export PATH="$FLUTTER_ROOT/bin:$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/build-tools/$BUILD_TOOLS:$PATH"

    log "Accepting Android licenses..."
    yes | flutter doctor --android-licenses >/dev/null 2>&1 || true

    log "Running flutter doctor..."
    echo ""
    flutter doctor
    echo ""
    log "Installation complete!"
}

# ─── Create test project & build APK ────────────────────────────────
test_build() {
    step "T" "Test build"
    export ANDROID_HOME="$SDK_ROOT"
    export JAVA_HOME="/data/data/com.termux/files/usr"
    export PATH="$FLUTTER_ROOT/bin:$SDK_ROOT/cmdline-tools/latest/bin:$SDK_ROOT/build-tools/$BUILD_TOOLS:$PATH"

    local TEST_DIR="$HOME/flutter_test_app"
    if [ ! -d "$TEST_DIR" ]; then
        log "Creating test project..."
        flutter create --org com.test --project-name test_app "$TEST_DIR" 2>&1 | tail -3
    fi

    log "Building debug APK..."
    cd "$TEST_DIR"
    if flutter build apk --debug 2>&1 | tail -3; then
        echo ""
        log "============================================"
        log "SUCCESS! APK built at:"
        log "  $TEST_DIR/build/app/outputs/flutter-apk/app-debug.apk"
        log "============================================"
    else
        err "Build failed. Check flutter doctor output above."
    fi
}

# ─── Wireless ADB instructions ──────────────────────────────────────
print_adb_instructions() {
    step "ADB" "Wireless ADB Setup"
    cat << 'EOF'
To debug apps wirelessly:

  1. Enable Developer Options (tap Build Number 7 times)
  2. Enable Wireless Debugging in Developer Options
  3. Pair (first time only):
       adb pair localhost:<pairing-port>
       # Enter the pairing code from screen
  4. Connect:
       adb connect localhost:<connect-port>
  5. Verify:
       adb devices
  6. Run your app:
       cd your_project && flutter run

To install APK on another device on same network:
  adb connect <device-ip>:<port>
  adb install app-debug.apk
EOF
}

# ─── Main ────────────────────────────────────────────────────────────
main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════════════╗"
    echo "║   Flutter on Termux - Automated Installer        ║"
    echo "║   For aarch64 Android devices                    ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo -e "${NC}"

    preflight
    install_system_packages
    install_android_sdk
    install_flutter
    patch_flutter_platform
    install_native_ndk
    fix_cmake_ninja
    setup_environment
    setup_gradle
    verify_installation
    test_build
    print_adb_instructions

    echo ""
    log "Restart your shell or run: source ~/.bashrc"
    log "Then use: flutter create my_app && cd my_app && flutter run"
}

main "$@"
