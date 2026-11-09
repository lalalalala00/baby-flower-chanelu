#!/bin/sh
# 맥용 데스크톱 펫 바이너리 빌드 (Apple Silicon + Intel 유니버설)
set -e
cd "$(dirname "$0")/.."
mkdir -p bin build
# 버전은 package.json에서 가져와요 (VS Code 확장이 예전 샤네루를 알아보는 데 써요)
VERSION=$(sed -n 's/^  "version": "\(.*\)",$/\1/p' package.json)
echo "let helperVersion = \"$VERSION\"" > build/Version.swift
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos11 desktop/main.swift build/Version.swift -o build/chanelu-desktop-$arch
done
lipo -create build/chanelu-desktop-arm64 build/chanelu-desktop-x86_64 -output bin/chanelu-desktop
codesign --force -s - bin/chanelu-desktop
rm -rf build
ls -la bin/chanelu-desktop
