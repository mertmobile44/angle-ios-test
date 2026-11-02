#!/bin/bash
# Imzasiz .app -> .ipa (Payload/). Imza Windows'ta Sideloadly / AltStore ile ucretsiz Apple kimligiyle atilir.
# Kullanim: ios/scripts/ipa_paketle.sh <Uygulama.app> <cikti.ipa>
set -euo pipefail
APP="$1"; IPA="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
[ -d "$APP" ] || { echo "app yok: $APP"; exit 1; }
TMP="$(mktemp -d)"
mkdir -p "$TMP/Payload"
cp -R "$APP" "$TMP/Payload/"
# Gomulu ANGLE cerceveleri: basliklar ve imza artiklari kaldirilir (Sideloadly yeniden imzalar)
find "$TMP/Payload" -name "_CodeSignature" -type d -prune -exec rm -rf {} +
find "$TMP/Payload" -path "*/Frameworks/*.framework/Headers" -type d -prune -exec rm -rf {} +
(cd "$TMP" && zip -qry "$IPA.tmp" Payload)
mv "$IPA.tmp" "$IPA"
rm -rf "$TMP"
echo "IPA: $IPA ($(du -h "$IPA" | cut -f1))"
