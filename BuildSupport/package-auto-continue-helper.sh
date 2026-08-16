#!/bin/sh
set -eu

resources_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
agents_dir="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchAgents"
helper_output="$resources_dir/VeoAutoContinueAgent"
swift_compiler="$(xcrun --find swiftc)"

mkdir -p "$resources_dir" "$agents_dir"
helper_parts=""
for helper_arch in $ARCHS; do
  helper_part="$TEMP_DIR/VeoAutoContinueAgent-$helper_arch"
  "$swift_compiler" \
    -parse-as-library \
    -target "$helper_arch-apple-macos$MACOSX_DEPLOYMENT_TARGET" \
    -sdk "$SDKROOT" \
    "$SRCROOT/BuildSupport/VeoAutoContinueAgent.swift" \
    -o "$helper_part"
  helper_parts="$helper_parts $helper_part"
done

if [ "$(echo "$ARCHS" | wc -w | tr -d ' ')" -gt 1 ]; then
  xcrun lipo -create $helper_parts -output "$helper_output"
else
  cp $helper_parts "$helper_output"
fi
cp "$SRCROOT/BuildSupport/com.ash.Veo.AutoContinue.plist" \
  "$agents_dir/com.ash.Veo.AutoContinue.plist"
