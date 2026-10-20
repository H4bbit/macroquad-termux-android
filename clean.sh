#!/data/data/com.termux/files/usr/bin/bash

set -e

echo "[1/3] Cleaning Java build"
rm -rf build-java

echo "[2/3] Cleaning APK intermediates"
rm -rf \
    build-apk/base \
    build-apk/final \
    build-apk/inject \
    build-apk/reszip

echo "[3/3] Cleaning temporary artifacts"

find . -name "*.idsig" -delete
find . -name "*.apk" -delete

# target/ holds the whole Rust build (a cold release build takes minutes), so it
# is only removed on request. build/build-apk/debug.keystore is never removed:
# regenerating it would change the APK signature.
if [ "${1:-}" = "--full" ]; then
    echo
    echo "Full clean: removing target/"
    rm -rf target
fi

echo
echo "Clean complete."
