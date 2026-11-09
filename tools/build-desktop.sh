#!/bin/sh
# 맥용 데스크톱 펫 바이너리 빌드 (Apple Silicon + Intel 유니버설)
set -e
cd "$(dirname "$0")/.."
mkdir -p bin build
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos11 desktop/main.swift -o build/chanelu-desktop-$arch
done
lipo -create build/chanelu-desktop-arm64 build/chanelu-desktop-x86_64 -output bin/chanelu-desktop
codesign --force -s - bin/chanelu-desktop
rm -rf build
ls -la bin/chanelu-desktop
