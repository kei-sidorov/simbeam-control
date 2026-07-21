#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"
derived_data="$repo_dir/.build/UniversalDerivedData"
output_dir="$repo_dir/.build/release"

xcodebuild \
  -project "$repo_dir/simbeam-control.xcodeproj" \
  -scheme simbeam-control \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$derived_data" \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "$output_dir"
install -m 755 \
  "$derived_data/Build/Products/Release/simbeam-control" \
  "$output_dir/simbeam-control"

file "$output_dir/simbeam-control"
lipo -archs "$output_dir/simbeam-control"
