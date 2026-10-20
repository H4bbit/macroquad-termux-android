# Macroquad Termux Android

Rust + [macroquad](https://github.com/not-fl3/macroquad) Android build pipeline
running entirely inside Termux, without Android Studio, Gradle or `cargo-apk`.

This project demonstrates how to:
- Build a Rust `cdylib` for Android with the NDK
- Compile the miniquad Java side manually
- Generate DEX files manually
- Link Android resources manually
- Package and sign an APK manually
- Run macroquad on Android without `cargo-quad-apk`

Everything is built directly inside Termux (aarch64) using shell scripts and
command line tools. This project targets the Termux app from GitHub releases
only (the Play Store build is deprecated and unsupported) — paths, toolchain
and packaging choices below assume that environment.

---

## Overview

This repository is intentionally minimal and low-level. Instead of relying on
Android Studio, Gradle, `cargo-quad-apk` or the macroquad Docker image
(`notfl3/cargo-apk`, x86_64 only), it exposes the real packaging pipeline
step by step.

The goal is educational and practical:

- Understand how a Rust graphics stack is packaged for Android
- Understand miniquad's Android integration (Activity + `QuadSurface` + JNI)
- Understand manual APK assembly
- Allow macroquad development directly on-device inside Termux

The project intentionally avoids:

- Gradle
- Android Studio
- `cargo-apk` / `cargo-quad-apk`
- Android SDK binaries (`aapt2`, `d8`, `zipalign`, `apksigner` from the SDK do
  not execute inside Termux — the Termux-packaged equivalents are used)

---

## Features

- macroquad 0.4 on Android
- Rust `cdylib` loaded by a Java Activity (no `NativeActivity`)
- Manual APK packaging, DEX generation and native `.so` injection
- Touch input and multi-touch particle demo
- No Gradle, no Android Studio, no `cargo-apk`
- Release APK under 450 KiB with a single deflated native `.so`

---

## Current Demo

`src/lib.rs` runs a touch particle system:

- Fullscreen ES2 renderer through miniquad
- Multi-touch on device, mouse on desktop (same loop)
- Ring buffer of particles, no allocation per frame
- Frame-time clamp so a long frame does not erase every particle at once
- On-screen FPS and particle count

---

## Project Structure

```text
.
├── build.sh
├── clean.sh
├── gen-debug-key.sh
├── Cargo.toml
├── README.md
├── platform/
│   └── android/
│       ├── app/
│       │   ├── AndroidManifest.xml
│       │   └── res/            (icons and values, copied from the siblings)
│       └── java/
│           ├── MainActivity.java   (vendored from miniquad 0.4.11)
│           └── QuadNative.java     (vendored from miniquad 0.4.11)
├── src/
│   └── lib.rs
├── build-java/    (javac classes + dex, ignored)
├── build-apk/     (reszip, base, inject, final APK, ignored)
├── build/
│   └── build-apk/
│       └── debug.keystore
└── target/        (cargo output, ignored)
```

---

## Important Design Decisions

### Why no Gradle or Android Studio?
The point of the project is to prove that a Rust Android application can be
built entirely inside Termux. Gradle and Android Studio would defeat that, and
neither runs well in this environment.

### Why not `cargo-quad-apk`?
`cargo-quad-apk` is the official macroquad packaging tool, but it is a fork of
the archived `rust-mobile/android-rs-glue` and does not build on an aarch64
host: `src/ops/build/util.rs` defines `HOST_TAG` only for Windows, Linux
(x86_64) and macOS, so compiling the tool itself fails with
`error[E0425]: cannot find value HOST_TAG`. Its documented workflow also relies
on an x86_64 Docker image.

What the tool adds on top of a manual build is small: rewriting the `bin`
target into a `cdylib`, injecting the `quad_main` shim, and replacing two
placeholders in the Java sources. All three are handled here by
`src/lib.rs` and `build.sh`.

### Why an Activity instead of `NativeActivity`?
miniquad does not use `android.app.NativeActivity`. Its Java side owns the
`SurfaceView` (`QuadSurface`), forwards lifecycle and input events as JNI calls
and calls `System.loadLibrary` itself, so the APK needs a real `classes.dex`
and an Activity declared by the manifest.

### Why is the miniquad Java vendored?
`platform/android/java/` holds copies of `MainActivity.java` and
`QuadNative.java` from miniquad 0.4.11. Keeping them in the repository means
the build never depends on the cargo registry layout (`~/.cargo/registry/src/…`)
and upgrades are an explicit, reviewable diff. `build.sh` replaces two
placeholders — `TARGET_PACKAGE_NAME` and `LIBRARY_NAME` — and then asserts that
the substitution really happened.

### Why does `quad_main` exist in `src/lib.rs`?
A `cdylib` has no entry point. miniquad's `QuadNative.activityOnCreate` reaches
`quad_main()`, and that symbol has to live in the application crate — the
`cargo-quad-apk` injection does exactly this for `bin` targets. The macroquad
attribute macro only generates a plain `fn main()`, no `#[no_mangle]`, which is
why the shim is written by hand here.

### Why `minSdkVersion 26` and `targetSdkVersion 34`?
26 matches the `--min-api` value that `cargo-quad-apk` uses for `d8`, and the
installed Android platform stub is `android-34`. The manifest value, the
`aapt2 link` flags and `d8 --min-api` are kept identical on purpose.

### Why is `configChanges` so wide?
Recreating the Activity calls `QuadNative.activityOnCreate` again, which calls
`quad_main()` again while the previous game loop is still running. The manifest
therefore declares every configuration change that would normally recreate the
screen.

### Why environment variables instead of `.cargo/config.toml`?
`build.sh` exports `CARGO_TARGET_<TRIPLE>_LINKER`, `CC_*`, `CXX_*` and `AR_*`
for the selected ABI. This keeps an absolute NDK path out of the repository and
makes the ABI switch a one-line change.

### Why Termux packages instead of Android SDK binaries?
The SDK build tools are x86_64 ELF binaries and do not execute inside Termux.
The pipeline uses `aapt2`, `d8`, `zipalign` and `apksigner` from the Termux
repositories. The only piece taken from the Android SDK is the platform stub
`platforms/android-34/android.jar`, which is a plain jar used as a compile and
link reference.

---

## Dependencies

| Dependency | Minimum | Notes |
|---|---|---|
| Termux (aarch64) | — | provides `$PREFIX`, `pkg` packages below |
| Rust | 1.85 | edition 2024; `rust-std` for `aarch64-linux-android` |
| Android SDK platform | `android-34` | only `platforms/android-34/android.jar` is used |
| Termux-adapted NDK (`termux-ndk`) | r29 (aarch64) | provides `toolchains/llvm/prebuilt/linux-aarch64` |
| openjdk-17 | 17 | `javac`, `keytool` |
| aapt2, d8, apksigner, zipalign, zip | — | all via `pkg` |

---

## Termux Setup

Install required packages:

```bash
pkg update
pkg install \
  rust \
  openjdk-17 \
  aapt2 \
  d8 \
  apksigner \
  zipalign \
  zip
```

The Termux `rust` package already ships the Android standard library
(`aarch64-linux-android`, `armv7-linux-androideabi`, `i686-linux-android`,
`x86_64-linux-android`), so no extra target setup is needed.

## Android SDK Setup

The build expects two environment variables pointing wherever each piece was
installed (no fixed location required):

- `ANDROID_HOME` — an Android SDK whose `platforms/android-34/` holds
  `android.jar` (only this stub is used from the SDK). Install it with the SDK
  command-line tools:

```bash
sdkmanager "platforms;android-34"
```

- `ANDROID_NDK_HOME` — the extracted Termux-adapted NDK root (the directory
  containing `build/cmake/android.toolchain.cmake`).

```bash
export ANDROID_HOME=<your-sdk-dir>
export ANDROID_NDK_HOME=<your-ndk-dir>
```

Only the platform stub is used from the SDK — packaging tools (`aapt2`, `d8`,
`zipalign`, `apksigner`) come from the Termux packages above.

## Android NDK

This project uses `termux-ndk`.

The official Android NDK does not integrate cleanly with Termux in many cases.
The Termux-adapted NDK avoids several compatibility issues.

Download the Termux-adapted NDK tarball (do NOT clone the repo — it does not
contain a usable NDK tree) and extract it to a directory of your choice:

```bash
mkdir -p <ndk-parent-dir>
curl -sL https://github.com/lzhiyong/termux-ndk/releases/download/android-ndk/android-ndk-r29-aarch64.tar.xz \
  | tar -xJ -C <ndk-parent-dir>
```

Then set `ANDROID_NDK_HOME` to the extracted NDK root — the directory containing
`build/cmake/android.toolchain.cmake` (check with `ls`, as the tarball creates a
versioned subdirectory).

---

## Build Instructions

### Generate the debug keystore

```bash
./gen-debug-key.sh
```

### Build the APK

```bash
./build.sh            # release (lto, codegen-units = 1)
./build.sh debug      # debug (fast to compile, slow to run)
```

Output:

```text
build-apk/final/app-signed.apk
```

### Clean build files

```bash
./clean.sh            # Java/APK intermediates and APKs
./clean.sh --full     # also removes target/ (forces a full Rust rebuild)
```

---

## Build Pipeline

`build.sh` runs eight steps:

1. **Native build** — `cargo build --target aarch64-linux-android` with the NDK
   clang wrapper exported as linker/`CC`/`CXX`; produces
   `libmacroquad_android.so`.
2. **Prepare Java** — copies the vendored Java sources, replaces
   `TARGET_PACKAGE_NAME` and `LIBRARY_NAME`, asserts the result.
3. **Compile Java** — `javac --release 8 -classpath android.jar`.
4. **Dex** — `d8 --min-api 26 --lib android.jar`.
5. **Compile resources** — `aapt2 compile --dir platform/android/app/res`.
6. **Link APK** — `aapt2 link` with `--min-sdk-version`, `--target-sdk-version`
   and `-A` when `platform/android/app/assets` exists.
7. **Inject** — `zip -u` of `lib/<abi>/libmacroquad_android.so` and
   `classes.dex` into the unaligned APK.
8. **Align and sign** — `zipalign -f 4` and
   `apksigner sign --ks-pass/--key-pass`.

The signed APK is about **438 KiB** and contains a ~940 KiB
`libmacroquad_android.so`.

---

## Verifying the APK

```bash
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-aarch64/bin"

# JNI entry points and the quad_main shim must be exported by the .so
"$NDK_BIN/llvm-nm" -D --defined-only \
  target/aarch64-linux-android/release/libmacroquad_android.so |
  grep -E 'quad_main|Java_quad'

# 11 Java_quad_1native_QuadNative_* symbols + quad_main expected

unzip -l build-apk/final/app-signed.apk | grep -E '\.so|classes.dex|resources.arsc'
zipalign -c -v 4 build-apk/final/app-signed.apk | tail -1
apksigner verify --print-certs build-apk/final/app-signed.apk
```

The `#[no_mangle]` symbols that miniquad defines inside its own crate survive
into the final `cdylib` with the NDK r29 linker, so no extra glue is needed
beyond `quad_main`.

---

## Notes and Limitations

- Only one ABI per build (`ANDROID_ABI=arm64-v8a` by default). The
  `ANDROID_ABI` switch maps to a Rust target and an NDK triple; the matching
  `rust-std` target must be installed.
- The `.so` is stored deflated inside the APK. `android:extractNativeLibs`
  defaults to `true`, so it is extracted at install time; storing it
  uncompressed would need 4 KiB page alignment for API 30+.
- Audio (`quad-snd`) is not enabled by the current dependency set.
- `javac` prints a deprecation note from miniquad's own
  `setSystemUiVisibility` usage; it is harmless.
