#!/bin/bash
# ANGLE'i iOS arm64 icin yalniz Metal arka ucuyla derler. macOS + Xcode gerekir (bulut macOS yeterli).
# Cikti: $CIKTI/libEGL.framework, $CIKTI/libGLESv2.framework, $CIKTI/include (EGL, GLES2, GLES3, KHR)
# Kullanim: ios/scripts/angle_derle.sh [cikti_klasoru]
# Durum (2026-11-02): yazildi, henuz calistirilmadi. gn arguman adlari ANGLE surumune gore degisebilir (hata olursa
# out/ios-arm64/args.gn ve `gn args out/ios-arm64 --list` ile kontrol). Ilk calisma 30-60 dk + ~10 GB indirme (depot_tools/gclient).
set -euo pipefail
CIKTI="${1:-$PWD/angle_ios}"
IS="${ANGLE_IS:-$HOME/angle_is}"
SURUM="${ANGLE_SURUM:-main}"	# tekrar uretilebilirlik icin ilk basarili calismadan sonra commit sabitlenmeli
mkdir -p "$IS" "$CIKTI"
cd "$IS"
[ -d depot_tools ] || git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
export PATH="$IS/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
if [ ! -d angle ]; then
  git clone https://chromium.googlesource.com/angle/angle
fi
cd angle
git fetch origin "$SURUM" && git checkout -q FETCH_HEAD
python3 scripts/bootstrap.py
# iOS bagimliliklari (DEPS checkout_ios) icin .gclient dosyasina hedef isletim sistemi eklenir
G=".gclient"; [ -f "$G" ] || G="../.gclient"
grep -q "target_os" "$G" || echo 'target_os = ["ios"]' >> "$G"
gclient sync --no-history -j8
gn gen out/ios-arm64 --args='
  target_os="ios"
  target_cpu="arm64"
  target_environment="device"
  is_debug=false
  is_component_build=false
  ios_enable_code_signing=false
  angle_enable_metal=true
  angle_enable_vulkan=false
  angle_enable_gl=false
  angle_enable_swiftshader=false
  angle_enable_null=false
  angle_build_tests=false
  angle_has_frame_capture=false'
autoninja -C out/ios-arm64 libEGL libGLESv2
rm -rf "$CIKTI/libEGL.framework" "$CIKTI/libGLESv2.framework" "$CIKTI/include"
cp -R out/ios-arm64/libEGL.framework out/ios-arm64/libGLESv2.framework "$CIKTI/"
cp -R include "$CIKTI/include"
git rev-parse HEAD > "$CIKTI/ANGLE_COMMIT.txt"
echo "ANGLE hazir: $CIKTI ($(cat "$CIKTI/ANGLE_COMMIT.txt"))"
