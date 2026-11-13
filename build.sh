#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/一页待办.app"
ICONSET=".build/AppIcon.iconset"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$((size * 2))" "$((size * 2))" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/OnePage.icns"
cp Assets/AppIcon.png "$APP/Contents/Resources/AppIcon.png"
cp .build/release/OnePage "$APP/Contents/MacOS/OnePage"
cp Info.plist "$APP/Contents/Info.plist"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :OnePageCloudKitEnabled' Info.plist)" == "true" ]]; then
    : "${ONEPAGE_SIGNING_IDENTITY:?CloudKit 构建需要开发者签名证书名称}"
    : "${ONEPAGE_ENTITLEMENTS_FILE:?CloudKit 构建需要匹配容器与推送能力的 entitlements 文件}"
    : "${ONEPAGE_PROVISIONING_PROFILE:?CloudKit 构建需要对应的 Mac 描述文件}"
    test -s "$ONEPAGE_ENTITLEMENTS_FILE"
    test -s "$ONEPAGE_PROVISIONING_PROFILE"
    cp "$ONEPAGE_PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"
    codesign --force --sign "$ONEPAGE_SIGNING_IDENTITY" --entitlements "$ONEPAGE_ENTITLEMENTS_FILE" "$APP"
else
    codesign --force --sign - "$APP"
fi
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$APP"
printf 'Built %s\n' "$PWD/$APP"
