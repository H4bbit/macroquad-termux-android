#!/data/data/com.termux/files/usr/bin/bash
#
# macroquad-termux-android — Rust/macroquad APK assembled by hand in Termux,
# with no Gradle and no cargo-apk.
#
# Pipeline (8 steps):
#   cargo (NDK cdylib) → miniquad Java (placeholders replaced) → javac →
#   d8 → aapt2 compile → aapt2 link → zip inject → zipalign + apksigner
#
# Usage:
#   ./build.sh            release APK (lto, codegen-units=1)
#   ./build.sh debug      debug APK (fast to compile, slow to run)
#
# Output: build-apk/final/app-signed.apk

set -euo pipefail

PACKAGE_NAME="org.h4bbit.macroquad"
NATIVE_LIB="macroquad-android"

ANDROID_API=34
ANDROID_MIN_API=26
ANDROID_ABI=arm64-v8a

JAVA_SRC="platform/android/java"
APP_DIR="platform/android/app"

KEYSTORE="build/build-apk/debug.keystore"
KEYSTORE_PASS="android"

MODE="${1:-release}"
case "$MODE" in
    release)
        CARGO_PROFILE="release"
        ;;
    debug)
        CARGO_PROFILE="debug"
        ;;
    *)
        echo "unknown mode '$MODE' (expected: release | debug)" >&2
        exit 1
        ;;
esac

# Cargo names the file lib<crate>.so, so the name System.loadLibrary receives
# must be the crate name with '-' replaced by '_'.
LIB_NAME_JAVA="${NATIVE_LIB//-/_}"

case "$ANDROID_ABI" in
    arm64-v8a)
        RUST_TARGET="aarch64-linux-android"
        NDK_TRIPLE="aarch64-linux-android"
        ;;
    armeabi-v7a)
        RUST_TARGET="armv7-linux-androideabi"
        NDK_TRIPLE="armv7a-linux-androideabi"
        ;;
    x86_64)
        RUST_TARGET="x86_64-linux-android"
        NDK_TRIPLE="x86_64-linux-android"
        ;;
    x86)
        RUST_TARGET="i686-linux-android"
        NDK_TRIPLE="i686-linux-android"
        ;;
    *)
        echo "Unsupported ANDROID_ABI: $ANDROID_ABI" >&2
        exit 1
        ;;
esac

# --------------------------------------------------
# Validation
# --------------------------------------------------

# Environment variables are checked before use: under `set -u` a missing one
# aborts with "unbound variable" instead of a useful message.
if [ -z "${PREFIX:-}" ]; then
    echo "error: PREFIX is not set (Termux)" >&2
    exit 1
fi

if [ -z "${ANDROID_HOME:-}" ]; then
    echo "error: ANDROID_HOME is not set" >&2
    exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}" ]; then
    echo "error: ANDROID_NDK_HOME is not set" >&2
    exit 1
fi

ANDROID_JAR="$ANDROID_HOME/platforms/android-${ANDROID_API}/android.jar"

# The prebuilt must match the Termux host (aarch64); the linux-x86_64 prebuilt
# shipped with upstream NDK releases cannot execute here.
NDK_PREBUILT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-aarch64"
NDK_BIN="$NDK_PREBUILT/bin"

JAVA="$PREFIX/lib/jvm/java-17-openjdk/bin"

if [ ! -f "$ANDROID_JAR" ]; then
    echo "error: missing $ANDROID_JAR" >&2
    exit 1
fi

if [ ! -d "$NDK_BIN" ]; then
    echo "error: missing NDK toolchain at $NDK_BIN" >&2
    exit 1
fi

if [ ! -x "$JAVA/javac" ]; then
    echo "error: missing javac at $JAVA/javac" >&2
    exit 1
fi

if [ ! -f "$KEYSTORE" ]; then
    echo "Missing $KEYSTORE"
    echo
    echo "Generate one with:"
    echo "./gen-debug-key.sh"
    exit 1
fi

if [ ! -f Cargo.toml ]; then
    echo "error: missing Cargo.toml" >&2
    exit 1
fi

for file in "$JAVA_SRC/MainActivity.java" "$JAVA_SRC/QuadNative.java"; do
    if [ ! -f "$file" ]; then
        echo "error: missing $file" >&2
        exit 1
    fi
done

for path in "$APP_DIR/AndroidManifest.xml" "$APP_DIR/res"; do
    if [ ! -e "$path" ]; then
        echo "error: missing $path" >&2
        exit 1
    fi
done

# NDK clang wrappers are named after the exact API level and only exist from
# API 21 upwards, so use the requested level or the first one above it.
CLANG=""
for api in $(seq "$ANDROID_MIN_API" "$ANDROID_API"); do
    if [ -x "$NDK_BIN/${NDK_TRIPLE}${api}-clang" ]; then
        CLANG="$NDK_BIN/${NDK_TRIPLE}${api}-clang"
        break
    fi
done

if [ -z "$CLANG" ]; then
    echo "error: no NDK clang wrapper for ${NDK_TRIPLE} between API $ANDROID_MIN_API and $ANDROID_API" >&2
    exit 1
fi

# Cargo and the cc crate read per-target variables; exporting them here keeps
# an absolute NDK path out of a committed .cargo/config.toml.
ENV_TARGET="${RUST_TARGET//-/_}"
ENV_TARGET_UPPER="$(printf %s "$ENV_TARGET" | tr '[:lower:]' '[:upper:]')"

export "CARGO_TARGET_${ENV_TARGET_UPPER}_LINKER=$CLANG"
export "CC_${ENV_TARGET}=$CLANG"
export "CXX_${ENV_TARGET}=$CLANG"
export "AR_${ENV_TARGET}=$NDK_BIN/llvm-ar"

# --------------------------------------------------
# Native Build
# --------------------------------------------------

echo "[1/8] Native Build ($MODE)"

cargo build --target "$RUST_TARGET" --profile "$CARGO_PROFILE"

NATIVE_SO="target/$RUST_TARGET/$CARGO_PROFILE/lib${LIB_NAME_JAVA}.so"

if [ ! -f "$NATIVE_SO" ]; then
    echo "error: missing $NATIVE_SO" >&2
    echo
    echo "Check that Cargo.toml declares:"
    echo "[lib]"
    echo 'crate-type = ["cdylib"]'
    exit 1
fi

# --------------------------------------------------
# Prepare Java
# --------------------------------------------------

echo "[2/8] Prepare Java"

# miniquad ships its Java sources with placeholders because the package and
# library names are only known at packaging time. The copies kept in this repo
# stay identical to the crate's, without depending on the cargo registry.
PKG_DIR="$(printf %s "$PACKAGE_NAME" | tr . /)"

rm -rf build-java
mkdir -p "build-java/src/quad_native"
mkdir -p "build-java/src/${PKG_DIR}"

sed \
    -e "s/^package TARGET_PACKAGE_NAME;/package ${PACKAGE_NAME};/" \
    -e "s/System.loadLibrary(\"LIBRARY_NAME\");/System.loadLibrary(\"${LIB_NAME_JAVA}\");/" \
    "$JAVA_SRC/MainActivity.java" \
    > "build-java/src/${PKG_DIR}/MainActivity.java"

cp "$JAVA_SRC/QuadNative.java" build-java/src/quad_native/QuadNative.java

# Positive assertion: if miniquad renames the placeholders, the APK would ship
# the wrong package name and only fail on the device.
if ! grep -qx "package ${PACKAGE_NAME};" "build-java/src/${PKG_DIR}/MainActivity.java"; then
    echo "error: package not substituted in $JAVA_SRC/MainActivity.java" >&2
    exit 1
fi

if ! grep -q "System.loadLibrary(\"${LIB_NAME_JAVA}\");" "build-java/src/${PKG_DIR}/MainActivity.java"; then
    echo "error: library name not substituted in $JAVA_SRC/MainActivity.java" >&2
    exit 1
fi

# --------------------------------------------------
# Compile Java
# --------------------------------------------------

echo "[3/8] Compile Java"

rm -rf build-java/classes
mkdir -p build-java/classes

"$JAVA/javac" \
    --release 8 \
    -classpath "$ANDROID_JAR" \
    -d build-java/classes \
    $(find build-java/src -name "*.java")

# --------------------------------------------------
# Dex
# --------------------------------------------------

echo "[4/8] Dex"

rm -rf build-java/dex
mkdir -p build-java/dex

d8 \
    --min-api "$ANDROID_MIN_API" \
    --lib "$ANDROID_JAR" \
    --output build-java/dex \
    $(find build-java/classes -name "*.class" | sort)

# --------------------------------------------------
# Compile Resources
# --------------------------------------------------

echo "[5/8] Compile Resources"

rm -rf build-apk/reszip
mkdir -p build-apk/reszip

aapt2 compile \
    --dir "$APP_DIR/res" \
    -o build-apk/reszip/resources.zip

# --------------------------------------------------
# Link APK
# --------------------------------------------------

echo "[6/8] Link APK"

rm -rf build-apk/base
mkdir -p build-apk/base

ASSETS_ARG=""
if [ -d "$APP_DIR/assets" ]; then
    ASSETS_ARG="-A $APP_DIR/assets"
fi

aapt2 link \
    -I "$ANDROID_JAR" \
    --manifest "$APP_DIR/AndroidManifest.xml" \
    --min-sdk-version "$ANDROID_MIN_API" \
    --target-sdk-version "$ANDROID_API" \
    --auto-add-overlay \
    -o build-apk/base/app-unsigned.apk \
    $ASSETS_ARG \
    build-apk/reszip/resources.zip

# --------------------------------------------------
# Inject Native Libraries + Dex
# --------------------------------------------------

echo "[7/8] Inject Native + Dex"

rm -rf build-apk/inject
mkdir -p "build-apk/inject/lib/${ANDROID_ABI}"

cp "$NATIVE_SO" "build-apk/inject/lib/${ANDROID_ABI}/lib${LIB_NAME_JAVA}.so"
cp build-java/dex/classes.dex build-apk/inject/

(
    cd build-apk/inject
    zip -ur ../base/app-unsigned.apk .
)

# --------------------------------------------------
# Align + Sign APK
# --------------------------------------------------

echo "[8/8] Align + Sign APK"

rm -rf build-apk/final
mkdir -p build-apk/final

zipalign -f 4 \
    build-apk/base/app-unsigned.apk \
    build-apk/final/app-aligned.apk

apksigner sign \
    --ks "$KEYSTORE" \
    --ks-pass pass:"$KEYSTORE_PASS" \
    --key-pass pass:"$KEYSTORE_PASS" \
    --min-sdk-version "$ANDROID_MIN_API" \
    --out build-apk/final/app-signed.apk \
    build-apk/final/app-aligned.apk

echo
echo "Build complete:"
echo "build-apk/final/app-signed.apk"
