// SVFishingPlugin.mm
// iOS dylib plugin for Stardew Valley 1.6.15 AOT builds.
// Purpose:
// 1. Confirm plugin injection by writing Documents/sv_fishing_plugin.log.
// 2. Enumerate loaded images and locate StardewValley main executable base.
// 3. Provide a safe offset-patch mechanism driven by Documents/sv_fishing_patch.txt.
//
// This is intentionally offset-driven because iOS .NET AOT removes editable IL bodies.
// After locating the native BobberBar/FishingRod patch point in IDA/Hopper/Ghidra,
// put offsets in sv_fishing_patch.txt and inject this dylib through signing tools.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static NSString *SVDocumentsPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *SVLogPath(void) {
    return [SVDocumentsPath() stringByAppendingPathComponent:@"sv_fishing_plugin.log"];
}

static void SVLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *stamp = [[NSDate date] descriptionWithLocale:nil];
    NSString *full = [NSString stringWithFormat:@"[%@] %@\n", stamp, line];
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:SVLogPath()];
    if (!handle) {
        [full writeToFile:SVLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:[full dataUsingEncoding:NSUTF8StringEncoding]];
    [handle closeFile];
}

static bool SVIsMainStardewImage(const char *path) {
    if (!path) return false;
    NSString *p = [NSString stringWithUTF8String:path];
    return [p hasSuffix:@"/StardewValley.app/StardewValley"] || [p hasSuffix:@"/StardewValley"];
}

static uintptr_t SVFindMainImageBase(const struct mach_header_64 **outHeader) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!SVIsMainStardewImage(name)) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (outHeader) *outHeader = header;
        SVLog(@"main image: %s header=%p slide=0x%llx base=0x%llx", name, header, (unsigned long long)slide, (unsigned long long)((uintptr_t)header));
        return (uintptr_t)header;
    }
    return 0;
}

static void SVLogLoadedImages(void) {
    uint32_t count = _dyld_image_count();
    SVLog(@"loaded image count=%u", count);
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "Stardew") || strstr(name, "MonoGame") || strstr(name, ".dylib")) {
            SVLog(@"image[%u] %s header=%p slide=0x%llx", i, name, _dyld_get_image_header(i), (unsigned long long)_dyld_get_image_vmaddr_slide(i));
        }
    }
}

static bool SVWriteMemory(void *address, const uint8_t *bytes, size_t length) {
    if (!address || !bytes || length == 0) return false;
    uintptr_t pageSize = (uintptr_t)getpagesize();
    uintptr_t start = (uintptr_t)address & ~(pageSize - 1);
    uintptr_t end = ((uintptr_t)address + length + pageSize - 1) & ~(pageSize - 1);
    size_t protectLength = end - start;

    if (mprotect((void *)start, protectLength, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
        SVLog(@"mprotect RWX failed addr=%p errno=%d", address, errno);
        return false;
    }
    memcpy(address, bytes, length);
    __builtin___clear_cache((char *)address, (char *)address + length);
    mprotect((void *)start, protectLength, PROT_READ | PROT_EXEC);
    return true;
}

static NSData *SVHexToData(NSString *hex) {
    NSMutableString *clean = [NSMutableString string];
    for (NSUInteger i = 0; i < hex.length; i++) {
        unichar c = [hex characterAtIndex:i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
            [clean appendFormat:@"%C", c];
        }
    }
    if (clean.length % 2 != 0) return nil;
    NSMutableData *data = [NSMutableData dataWithCapacity:clean.length / 2];
    for (NSUInteger i = 0; i < clean.length; i += 2) {
        NSString *byteString = [clean substringWithRange:NSMakeRange(i, 2)];
        unsigned int value = 0;
        [[NSScanner scannerWithString:byteString] scanHexInt:&value];
        uint8_t b = (uint8_t)value;
        [data appendBytes:&b length:1];
    }
    return data;
}

static void SVApplyOffsetPatches(void) {
    uintptr_t base = SVFindMainImageBase(NULL);
    if (!base) {
        SVLog(@"main image not found; skip patches");
        return;
    }

    NSString *patchPath = [SVDocumentsPath() stringByAppendingPathComponent:@"sv_fishing_patch.txt"];
    NSString *text = [NSString stringWithContentsOfFile:patchPath encoding:NSUTF8StringEncoding error:nil];
    if (text.length == 0) {
        SVLog(@"patch file not found: %@", patchPath);
        SVLog(@"patch file format: offset_hex=bytes_hex, example: 0x123456=00008052C0035FD6");
        return;
    }

    NSArray<NSString *> *lines = [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0 || [line hasPrefix:@"#"]) continue;
        NSArray<NSString *> *parts = [line componentsSeparatedByString:@"="];
        if (parts.count != 2) {
            SVLog(@"invalid patch line: %@", line);
            continue;
        }
        unsigned long long offset = 0;
        [[NSScanner scannerWithString:[parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]] scanHexLongLong:&offset];
        NSData *bytes = SVHexToData(parts[1]);
        if (offset == 0 || bytes.length == 0) {
            SVLog(@"invalid patch value: %@", line);
            continue;
        }
        void *target = (void *)(base + (uintptr_t)offset);
        bool ok = SVWriteMemory(target, (const uint8_t *)bytes.bytes, bytes.length);
        SVLog(@"patch offset=0x%llx target=%p len=%lu ok=%d", offset, target, (unsigned long)bytes.length, ok ? 1 : 0);
    }
}

static void SVWriteFishingSymbolHints(void) {
    NSString *hintPath = [SVDocumentsPath() stringByAppendingPathComponent:@"sv_fishing_hints.txt"];
    NSString *hints = @
    "Stardew Valley iOS 1.6.15 fishing patch hints\n"
    "===========================================\n"
    "This build is .NET iOS AOT. StardewValley.dll contains metadata only; native code is in StardewValley Mach-O.\n\n"
    "Useful metadata strings found in StardewValley.dll:\n"
    "BobberBar\n"
    "FishingRod\n"
    "pullFishFromWater\n"
    "doneFishing\n"
    "distanceFromCatching\n"
    "bobberPosition\n"
    "fishPosition\n"
    "treasurePosition\n"
    "treasureCaught\n"
    "whichFish\n\n"
    "Recommended first native patch target:\n"
    "BobberBar update logic: force distanceFromCatching to full, or force success branch.\n\n"
    "sv_fishing_patch.txt format in Documents:\n"
    "# offset_hex=arm64_bytes_hex\n"
    "# example RET: 0x123456=C0035FD6\n"
    "# example MOV W0,#1; RET: 0x123456=20008052C0035FD6\n";
    [hints writeToFile:hintPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

__attribute__((constructor)) static void SVFishingPluginMain(void) {
    @autoreleasepool {
        SVLog(@"SVFishingPlugin loaded");
        SVLog(@"bundle=%@", [[NSBundle mainBundle] bundlePath]);
        SVLog(@"documents=%@", SVDocumentsPath());
        SVLogLoadedImages();
        SVWriteFishingSymbolHints();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SVLog(@"applying offset patches after delay");
            SVApplyOffsetPatches();
        });
    }
}
