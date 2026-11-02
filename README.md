# angle-ios-test

ANGLE (Metal backend) GLES3 compatibility test for iOS arm64: shader with highp/int uniforms, RGBA8 texture + mipmaps,
client-side vertex arrays, VBO/IBO + glBufferSubData, stencil, render-to-texture. Six squares on screen (green = pass),
details in `Documents/angle_test_log.txt` (iTunes File Sharing).

CI (GitHub Actions, macos-14): builds ANGLE from source (`scripts/angle_derle.sh`), the test app, and an **unsigned** IPA
(artifact `AngleIOSTest`). Sign/install on device with your own Apple ID (e.g. Sideloadly).
