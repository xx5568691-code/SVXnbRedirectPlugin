#!/bin/sh
set -e
xcrun --sdk iphoneos clang++ -arch arm64 -dynamiclib \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=12.0 \
  -framework Foundation -framework UIKit \
  -fobjc-arc SVXnbRedirectPlugin.mm fishhook.c \
  -o SVXnbRedirectPlugin.dylib
file SVXnbRedirectPlugin.dylib
