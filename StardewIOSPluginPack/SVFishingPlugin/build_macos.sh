#!/bin/sh
set -e
xcrun --sdk iphoneos clang++ -arch arm64 -dynamiclib \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -framework Foundation -framework UIKit \
  -fobjc-arc SVFishingPlugin.mm \
  -o SVFishingPlugin.dylib
echo "Built SVFishingPlugin.dylib"
