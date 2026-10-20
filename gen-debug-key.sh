#!/data/data/com.termux/files/usr/bin/bash

set -e

KEYSTORE="build/build-apk/debug.keystore"

if [ -f "$KEYSTORE" ]; then
    echo "debug.keystore already exists:"
    echo "$KEYSTORE"
    exit 0
fi

mkdir -p "$(dirname "$KEYSTORE")"

echo "Generating Android debug keystore..."

keytool -genkeypair \
    -v \
    -keystore "$KEYSTORE" \
    -storepass android \
    -alias androiddebugkey \
    -keypass android \
    -keyalg RSA \
    -keysize 2048 \
    -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"

echo
echo "Debug keystore created:"
echo "$KEYSTORE"
