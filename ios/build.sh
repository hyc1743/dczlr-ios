#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodebuild >/dev/null || ! command -v xcodegen >/dev/null; then
  echo "Requires macOS, Xcode and XcodeGen. Install XcodeGen with: brew install xcodegen" >&2
  exit 1
fi

mode="${1:-simulator}"
case "$mode" in
  simulator) sdk=iphonesimulator; destination='generic/platform=iOS Simulator' ;;
  device) sdk=iphoneos; destination='generic/platform=iOS' ;;
  *) echo "Usage: bash build.sh [simulator|device]" >&2; exit 2 ;;
esac

xcodegen generate --spec project.yml
xcodebuild -project PortLab.xcodeproj -scheme PortLab -configuration Debug \
  -sdk "$sdk" -destination "$destination" -derivedDataPath "build/$mode" \
  CODE_SIGNING_ALLOWED=NO build

if [ "$mode" = device ]; then
  package_dir="$(mktemp -d "$PWD/build/package.XXXXXX")"
  mkdir -p "$package_dir/Payload"
  ditto build/device/Build/Products/Debug-iphoneos/PortLab.app "$package_dir/Payload/PortLab.app"
  ditto -c -k --keepParent "$package_dir/Payload" build/DCZL-R-unsigned.ipa
  echo "Unsigned device package: $PWD/build/DCZL-R-unsigned.ipa"
fi
