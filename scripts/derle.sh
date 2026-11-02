#!/bin/bash
# ANGLE (iOS arm64, Metal) + test uygulamasi -> imzasiz IPA (cikti/AngleIOSTest.ipa). macOS + Xcode.
set -euo pipefail
KOK="$(cd "$(dirname "$0")/.." && pwd)"
ANGLE="${ANGLE:-$KOK/angle_ios}"
[ -d "$ANGLE/libGLESv2.framework" ] || bash "$KOK/scripts/angle_derle.sh" "$ANGLE"
cmake -S "$KOK" -B "$KOK/build" -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
      -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DANGLE_DIR="$ANGLE" -DANGLE_INCLUDE="$ANGLE/include"
xcodebuild -project "$KOK/build/AngleIOSTest.xcodeproj" -target AngleIOSTest -configuration Release \
      -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO -quiet
mkdir -p "$KOK/cikti"
bash "$KOK/scripts/ipa_paketle.sh" "$KOK/build/Release-iphoneos/AngleIOSTest.app" "$KOK/cikti/AngleIOSTest.ipa"
cp "$ANGLE/ANGLE_COMMIT.txt" "$KOK/cikti/" 2>/dev/null || true
