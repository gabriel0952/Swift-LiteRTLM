#!/usr/bin/env bash
# Builds a real CLiteRTLM.xcframework from the official LiteRT-LM C API.
# Output: Frameworks/LiteRTLM.xcframework (consumed as a binary SPM target)

set -euo pipefail

REPO_URL="https://github.com/google-ai-edge/LiteRT-LM.git"
REF="${LITERT_LM_REF:-main}"
BAZEL="${BAZEL:-bazelisk}"
C_TARGET="${C_TARGET:-//c:libLiteRTLMEngine.dylib}"
PROVIDER_NAME="libGemmaModelConstraintProvider.dylib"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
OUTPUT="$FRAMEWORKS_DIR/LiteRTLM.xcframework"
BUILD_DIR="$(mktemp -d)/litert-lm-src"
WORK_DIR="$(mktemp -d)/litert-lm-framework"
DEVICE_DYLIB="$WORK_DIR/libLiteRTLMEngine-device.dylib"
SIM_DYLIB="$WORK_DIR/libLiteRTLMEngine-sim.dylib"

cleanup() {
  rm -rf "$BUILD_DIR" "$WORK_DIR"
}
trap cleanup EXIT

ensure_upstream_ios_build_support() {
  if grep -q 'ios_engine.bzl' c/BUILD && [ ! -f c/ios_engine.bzl ]; then
    cat > c/ios_engine.bzl <<'EOF'
"""Stub for ios_shared_engine macro when upstream has not published it yet."""

def ios_shared_engine(**kwargs):
    pass
EOF
  fi

  if ! grep -q 'name = "libLiteRTLMEngine.dylib"' c/BUILD; then
    cat >> c/BUILD <<'EOF'

cc_binary(
    name = "libLiteRTLMEngine.dylib",
    linkopts = [
        "-Wl,-exported_symbol,_litert_lm_*",
    ],
    linkshared = True,
    linkstatic = True,
    deps = [
        ":engine",
    ],
)
EOF
  fi
}

patch_upstream_stream_callback() {
  if grep -q 'callback(callback_data, text.data(),' c/engine.cc; then
    python3 - <<'PY'
from pathlib import Path

path = Path("c/engine.cc")
text = path.read_text()
old = """      for (const auto& text : responses->GetTexts()) {\n        callback(callback_data, text.data(), /*is_final=*/false,\n                 /*error_message=*/nullptr);\n      }\n"""
new = """      for (const auto& text : responses->GetTexts()) {\n        std::string chunk(text);\n        callback(callback_data, chunk.c_str(), /*is_final=*/false,\n                 /*error_message=*/nullptr);\n      }\n"""
if old not in text:
    raise SystemExit("Expected session stream callback block was not found in c/engine.cc")
path.write_text(text.replace(old, new, 1))
PY
  fi
}

build_slice() {
  local config="$1"
  local output_dylib="$2"

  echo "==> Building $C_TARGET for $config..."
  "$BAZEL" build --config="$config" "$C_TARGET" 2>&1 | tail -20
  cp bazel-bin/c/libLiteRTLMEngine.dylib "$output_dylib"
}

make_framework() {
  local slice_dir="$1"
  local dylib_path="$2"
  local provider_path="$3"

  mkdir -p "$slice_dir/CLiteRTLM.framework/Headers" "$slice_dir/CLiteRTLM.framework/Modules"
  cp "$dylib_path" "$slice_dir/CLiteRTLM.framework/CLiteRTLM"
  cp "$provider_path" "$slice_dir/CLiteRTLM.framework/$PROVIDER_NAME"
  install_name_tool -id "@rpath/CLiteRTLM.framework/CLiteRTLM" "$slice_dir/CLiteRTLM.framework/CLiteRTLM"
  cp "$BUILD_DIR/c/engine.h" "$slice_dir/CLiteRTLM.framework/Headers/litert_lm_c.h"

  cat > "$slice_dir/CLiteRTLM.framework/Modules/module.modulemap" <<'EOF'
framework module CLiteRTLM {
    header "litert_lm_c.h"
    export *
}
EOF

  cat > "$slice_dir/CLiteRTLM.framework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CLiteRTLM</string>
    <key>CFBundleIdentifier</key>
    <string>com.github.litertlm.CLiteRTLM</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>CLiteRTLM</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>MinimumOSVersion</key>
    <string>13.0</string>
</dict>
</plist>
EOF

  codesign --force --sign - "$slice_dir/CLiteRTLM.framework/CLiteRTLM" >/dev/null
  codesign --force --sign - "$slice_dir/CLiteRTLM.framework/$PROVIDER_NAME" >/dev/null
}

echo "==> Cloning LiteRT-LM..."
git clone --depth=1 --branch "$REF" "$REPO_URL" "$BUILD_DIR"
cd "$BUILD_DIR"

if command -v git-lfs >/dev/null 2>&1; then
  echo "==> Fetching Git LFS assets..."
  git lfs pull
fi

ensure_upstream_ios_build_support
patch_upstream_stream_callback

build_slice ios_arm64 "$DEVICE_DYLIB"
build_slice ios_sim_arm64 "$SIM_DYLIB"

make_framework "$WORK_DIR/ios-arm64" "$DEVICE_DYLIB" "$BUILD_DIR/prebuilt/ios_arm64/$PROVIDER_NAME"
make_framework "$WORK_DIR/ios-arm64-simulator" "$SIM_DYLIB" "$BUILD_DIR/prebuilt/ios_sim_arm64/$PROVIDER_NAME"

echo "==> Packaging XCFramework..."
rm -rf "$OUTPUT"
xcodebuild -create-xcframework \
  -framework "$WORK_DIR/ios-arm64/CLiteRTLM.framework" \
  -framework "$WORK_DIR/ios-arm64-simulator/CLiteRTLM.framework" \
  -output "$OUTPUT"

echo "==> Done: $OUTPUT"
echo
echo "Built from ref: $REF"
echo "Bazel target: $C_TARGET"
