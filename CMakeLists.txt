# ANGLE (Metal) GLES3 uyumluluk testi (iOS).
# macOS'ta (bulut ya da Mac):
#   cmake -S ios/angle_test -B build-angle-test -G Xcode -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
#         -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DANGLE_DIR=<libEGL.framework ve libGLESv2.framework klasoru> -DANGLE_INCLUDE=<angle/include>
#   xcodebuild -project build-angle-test/AngleIOSTest.xcodeproj -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO
# Imzasiz .app -> ios/scripts/ipa_paketle.sh -> Windows'ta Sideloadly ile ucretsiz Apple kimligiyle imzalanir.
cmake_minimum_required(VERSION 3.22)
project(AngleIOSTest LANGUAGES C CXX OBJC OBJCXX)

set(ANGLE_DIR "" CACHE PATH "libEGL.framework ve libGLESv2.framework iceren klasor")
set(ANGLE_INCLUDE "" CACHE PATH "ANGLE include klasoru (EGL/, GLES3/, KHR/)")
if(NOT ANGLE_DIR OR NOT ANGLE_INCLUDE)
    message(FATAL_ERROR "ANGLE_DIR ve ANGLE_INCLUDE verilmeli (ios/scripts/angle_derle.sh ciktisi)")
endif()

add_executable(AngleIOSTest MACOSX_BUNDLE main.mm)
target_include_directories(AngleIOSTest PRIVATE ${ANGLE_INCLUDE})
target_compile_options(AngleIOSTest PRIVATE -fobjc-arc)
target_link_libraries(AngleIOSTest PRIVATE
    "-framework UIKit" "-framework QuartzCore" "-framework Metal" "-framework Foundation"
    "${ANGLE_DIR}/libEGL.framework" "${ANGLE_DIR}/libGLESv2.framework")

set_target_properties(AngleIOSTest PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.example.angleiostest"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "15.0"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
    XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
    XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks"
    XCODE_EMBED_FRAMEWORKS "${ANGLE_DIR}/libEGL.framework;${ANGLE_DIR}/libGLESv2.framework"
    XCODE_EMBED_FRAMEWORKS_CODE_SIGN_ON_COPY "NO"
    XCODE_EMBED_FRAMEWORKS_REMOVE_HEADERS_ON_COPY "YES")
