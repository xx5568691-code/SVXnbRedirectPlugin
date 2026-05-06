// SVXnbRedirectPlugin.mm
// Stardew Valley iOS XNB redirect plugin.
//
// Purpose:
// Redirect reads for bundle Content/*.xnb files to Documents/CustomContent/*.xnb when
// the custom file exists. This helps iOS 1.6.15 load newly added XNB resources without
// patching managed DLL IL, which is unavailable in .NET iOS AOT builds.
//
// Example:
//   original: /.../StardewValley.app/Content/Maps/wind_valley_tiles.xnb
//   custom:   /.../Documents/CustomContent/Maps/wind_valley_tiles.xnb

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#import "fishhook.h"

static int (*orig_open)(const char *path, int oflag, ...) = NULL;
static int (*orig_openat)(int fd, const char *path, int oflag, ...) = NULL;
static FILE *(*orig_fopen)(const char *path, const char *mode) = NULL;
static int (*orig_access)(const char *path, int mode) = NULL;
static int (*orig_stat)(const char *path, struct stat *buf) = NULL;
static int (*orig_lstat)(const char *path, struct stat *buf) = NULL;

typedef void MonoDomain;
typedef void MonoAssembly;
typedef void MonoImage;
typedef void MonoClass;
typedef void MonoVTable;
typedef void MonoClassField;
typedef void MonoMethod;
typedef void MonoObject;
typedef void MonoString;

static MonoDomain *(*mono_domain_get_fn)(void) = NULL;
static MonoDomain *(*mono_get_root_domain_fn)(void) = NULL;
static void *(*mono_thread_attach_fn)(MonoDomain *domain) = NULL;
static void (*mono_assembly_foreach_fn)(void (*func)(MonoAssembly *, void *), void *user_data) = NULL;
static MonoImage *(*mono_assembly_get_image_fn)(MonoAssembly *assembly) = NULL;
static const char *(*mono_image_get_name_fn)(MonoImage *image) = NULL;
static MonoClass *(*mono_class_from_name_fn)(MonoImage *image, const char *name_space, const char *name) = NULL;
static MonoClassField *(*mono_class_get_field_from_name_fn)(MonoClass *klass, const char *name) = NULL;
static MonoVTable *(*mono_class_vtable_fn)(MonoDomain *domain, MonoClass *klass) = NULL;
static void (*mono_field_static_get_value_fn)(MonoVTable *vt, MonoClassField *field, void *value) = NULL;
static MonoClass *(*mono_object_get_class_fn)(MonoObject *obj) = NULL;
static MonoMethod *(*mono_class_get_method_from_name_fn)(MonoClass *klass, const char *name, int param_count) = NULL;
static MonoString *(*mono_string_new_fn)(MonoDomain *domain, const char *text) = NULL;
static MonoObject *(*mono_runtime_invoke_fn)(MonoMethod *method, void *obj, void **params, MonoObject **exc) = NULL;

struct SVManifestSearchState {
    MonoImage *image;
};

static NSString *SVDocumentsPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *SVLogPath(void) {
    return [SVDocumentsPath() stringByAppendingPathComponent:@"sv_xnb_redirect.log"];
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

static BOOL SVFileExists(NSString *path) {
    if (path.length == 0) return NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path];
}

static NSString *SVCustomContentRoot(void) {
    return [[SVDocumentsPath() stringByAppendingPathComponent:@"CustomContent"] stringByStandardizingPath];
}

static void SVLogFileProbe(NSString *label, NSString *path) {
    BOOL isDir = NO;
    BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
    unsigned long long size = 0;
    if (exists && !isDir) {
        NSDictionary<NSFileAttributeKey, id> *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        size = [attrs fileSize];
    }
    SVLog(@"probe %@ exists=%@ dir=%@ size=%llu path=%@", label, exists ? @"yes" : @"no", isDir ? @"yes" : @"no", size, path);
}

static NSString *SVBundleContentRoot(void) {
    return [[[[NSBundle mainBundle] bundlePath] stringByAppendingPathComponent:@"Content"] stringByStandardizingPath];
}

static void SVLogImportantFiles(void) {
    SVLogFileProbe(@"bundle Maps/panorama.xnb", [SVBundleContentRoot() stringByAppendingPathComponent:@"Maps/panorama.xnb"]);
    SVLogFileProbe(@"custom Maps/panorama.xnb", [SVCustomContentRoot() stringByAppendingPathComponent:@"Maps/panorama.xnb"]);
    SVLogFileProbe(@"bundle Maps/Farm.xnb", [SVBundleContentRoot() stringByAppendingPathComponent:@"Maps/Farm.xnb"]);
    SVLogFileProbe(@"custom Maps/Farm.xnb", [SVCustomContentRoot() stringByAppendingPathComponent:@"Maps/Farm.xnb"]);
}

static void *SVDlsymAny(const char *primary, const char *fallback) {
    void *symbol = dlsym(RTLD_DEFAULT, primary);
    if (!symbol && fallback) symbol = dlsym(RTLD_DEFAULT, fallback);
    return symbol;
}

static BOOL SVLoadMonoApi(void) {
    static BOOL attempted = NO;
    static BOOL loaded = NO;
    if (attempted) return loaded;
    attempted = YES;

    mono_domain_get_fn = (MonoDomain *(*)(void))SVDlsymAny("mono_domain_get", "mono_domain_get_internal");
    mono_get_root_domain_fn = (MonoDomain *(*)(void))SVDlsymAny("mono_get_root_domain", "mono_get_root_domain_internal");
    mono_thread_attach_fn = (void *(*)(MonoDomain *))SVDlsymAny("mono_thread_attach", "mono_thread_attach_internal");
    mono_assembly_foreach_fn = (void (*)(void (*)(MonoAssembly *, void *), void *))dlsym(RTLD_DEFAULT, "mono_assembly_foreach");
    mono_assembly_get_image_fn = (MonoImage *(*)(MonoAssembly *))dlsym(RTLD_DEFAULT, "mono_assembly_get_image");
    mono_image_get_name_fn = (const char *(*)(MonoImage *))dlsym(RTLD_DEFAULT, "mono_image_get_name");
    mono_class_from_name_fn = (MonoClass *(*)(MonoImage *, const char *, const char *))dlsym(RTLD_DEFAULT, "mono_class_from_name");
    mono_class_get_field_from_name_fn = (MonoClassField *(*)(MonoClass *, const char *))dlsym(RTLD_DEFAULT, "mono_class_get_field_from_name");
    mono_class_vtable_fn = (MonoVTable *(*)(MonoDomain *, MonoClass *))dlsym(RTLD_DEFAULT, "mono_class_vtable");
    mono_field_static_get_value_fn = (void (*)(MonoVTable *, MonoClassField *, void *))dlsym(RTLD_DEFAULT, "mono_field_static_get_value");
    mono_object_get_class_fn = (MonoClass *(*)(MonoObject *))dlsym(RTLD_DEFAULT, "mono_object_get_class");
    mono_class_get_method_from_name_fn = (MonoMethod *(*)(MonoClass *, const char *, int))dlsym(RTLD_DEFAULT, "mono_class_get_method_from_name");
    mono_string_new_fn = (MonoString *(*)(MonoDomain *, const char *))SVDlsymAny("mono_string_new", "mono_string_new_internal");
    mono_runtime_invoke_fn = (MonoObject *(*)(MonoMethod *, void *, void **, MonoObject **))dlsym(RTLD_DEFAULT, "mono_runtime_invoke");

    loaded = (mono_assembly_foreach_fn && mono_assembly_get_image_fn && mono_image_get_name_fn &&
              mono_class_from_name_fn && mono_class_get_field_from_name_fn && mono_class_vtable_fn &&
              mono_field_static_get_value_fn && mono_object_get_class_fn && mono_class_get_method_from_name_fn &&
              mono_string_new_fn && mono_runtime_invoke_fn && (mono_domain_get_fn || mono_get_root_domain_fn));
    SVLog(@"mono api loaded=%@", loaded ? @"yes" : @"no");
    if (!loaded) {
        SVLog(@"mono api detail: domain_get=%p root_domain=%p thread_attach=%p assembly_foreach=%p assembly_get_image=%p image_get_name=%p class_from_name=%p field_from_name=%p class_vtable=%p field_static_get=%p object_get_class=%p method_from_name=%p string_new=%p runtime_invoke=%p",
              mono_domain_get_fn, mono_get_root_domain_fn, mono_thread_attach_fn, mono_assembly_foreach_fn,
              mono_assembly_get_image_fn, mono_image_get_name_fn, mono_class_from_name_fn,
              mono_class_get_field_from_name_fn, mono_class_vtable_fn, mono_field_static_get_value_fn,
              mono_object_get_class_fn, mono_class_get_method_from_name_fn, mono_string_new_fn, mono_runtime_invoke_fn);
    }
    return loaded;
}

static void SVFindStardewAssembly(MonoAssembly *assembly, void *userData) {
    struct SVManifestSearchState *state = (struct SVManifestSearchState *)userData;
    if (state->image) return;
    MonoImage *image = mono_assembly_get_image_fn(assembly);
    if (!image) return;
    const char *name = mono_image_get_name_fn(image);
    if (!name) return;
    if (strcmp(name, "StardewValley") == 0 || strcmp(name, "StardewValley.dll") == 0) {
        state->image = image;
    }
}

static void SVCollectAssetNamesFromRoot(NSString *root, NSMutableSet<NSString *> *assets, NSString *label) {
    if (root.length == 0 || !assets) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        SVLog(@"manifest scan %@ skipped: missing %@", label, root);
        return;
    }

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    int count = 0;
    for (NSString *relative in enumerator) {
        NSString *full = [root stringByAppendingPathComponent:relative];
        BOOL itemIsDir = NO;
        if (![fm fileExistsAtPath:full isDirectory:&itemIsDir] || itemIsDir) continue;
        if (![[relative lowercaseString] hasSuffix:@".xnb"]) continue;

        NSString *asset = [[relative substringToIndex:relative.length - 4] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
        if (asset.length > 0) {
            [assets addObject:asset];
            count++;
        }
    }
    SVLog(@"manifest scan %@ found %d xnb under %@", label, count, root);
}

static NSArray<NSString *> *SVCustomAssetNames(void) {
    NSMutableSet<NSString *> *assets = [NSMutableSet set];
    SVCollectAssetNamesFromRoot(SVBundleContentRoot(), assets, @"bundle Content");
    SVCollectAssetNamesFromRoot(SVCustomContentRoot(), assets, @"Documents CustomContent");
    return assets.allObjects;
}

static BOOL SVHashSetAddString(MonoDomain *domain, MonoObject *hashSet, NSString *assetName) {
    if (!domain || !hashSet || assetName.length == 0) return NO;
    MonoClass *hashSetClass = mono_object_get_class_fn(hashSet);
    if (!hashSetClass) return NO;
    MonoMethod *addMethod = mono_class_get_method_from_name_fn(hashSetClass, "Add", 1);
    if (!addMethod) return NO;

    const char *utf8 = [assetName UTF8String];
    MonoString *monoString = mono_string_new_fn(domain, utf8);
    if (!monoString) return NO;
    void *args[1] = { monoString };
    MonoObject *exc = NULL;
    mono_runtime_invoke_fn(addMethod, hashSet, args, &exc);
    if (exc) {
        SVLog(@"manifest add exception: %@", assetName);
        return NO;
    }
    return YES;
}

static void SVPatchContentManifestNow(NSString *reason) {
    @autoreleasepool {
        NSArray<NSString *> *assets = SVCustomAssetNames();
        if (assets.count == 0) {
            SVLog(@"manifest patch skipped (%@): no xnb found in bundle Content or Documents CustomContent", reason);
            return;
        }
        if (!SVLoadMonoApi()) {
            SVLog(@"manifest patch skipped (%@): mono api unavailable", reason);
            return;
        }

        MonoDomain *domain = mono_domain_get_fn ? mono_domain_get_fn() : NULL;
        if (!domain && mono_get_root_domain_fn) domain = mono_get_root_domain_fn();
        if (!domain) {
            SVLog(@"manifest patch skipped (%@): no mono domain", reason);
            return;
        }
        if (mono_thread_attach_fn) mono_thread_attach_fn(domain);

        struct SVManifestSearchState state = { 0 };
        mono_assembly_foreach_fn(SVFindStardewAssembly, &state);
        if (!state.image) {
            SVLog(@"manifest patch skipped (%@): StardewValley assembly not loaded", reason);
            return;
        }

        MonoClass *klass = mono_class_from_name_fn(state.image, "StardewValley", "LocalizedContentManager");
        if (!klass) {
            SVLog(@"manifest patch skipped (%@): LocalizedContentManager class not found", reason);
            return;
        }
        MonoClassField *field = mono_class_get_field_from_name_fn(klass, "_manifest");
        if (!field) {
            SVLog(@"manifest patch skipped (%@): _manifest field not found", reason);
            return;
        }
        MonoVTable *vtable = mono_class_vtable_fn(domain, klass);
        if (!vtable) {
            SVLog(@"manifest patch skipped (%@): class vtable not found", reason);
            return;
        }

        MonoObject *manifest = NULL;
        mono_field_static_get_value_fn(vtable, field, &manifest);
        if (!manifest) {
            SVLog(@"manifest patch skipped (%@): _manifest is null, will retry later", reason);
            return;
        }

        int added = 0;
        for (NSString *asset in assets) {
            if (SVHashSetAddString(domain, manifest, asset)) added++;
        }
        SVLog(@"manifest patch %@: added/tried %d asset names from %@", reason, added, SVCustomContentRoot());
    }
}

static void SVScheduleManifestPatches(void) {
    NSArray<NSNumber *> *delays = @[ @1, @3, @6, @10, @20 ];
    for (NSNumber *delayNumber in delays) {
        int delay = delayNumber.intValue;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            SVPatchContentManifestNow([NSString stringWithFormat:@"after %ds", delay]);
        });
    }
}

static NSString *SVCustomPathForOriginal(NSString *original) {
    if (original.length == 0) return nil;
    NSString *normalized = [original stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
    NSRange contentRange = [normalized rangeOfString:@"/Content/" options:NSCaseInsensitiveSearch];
    if (contentRange.location == NSNotFound) return nil;

    NSString *relative = [normalized substringFromIndex:contentRange.location + @"/Content/".length];
    if (relative.length == 0) return nil;

    // Only redirect XNB content. This avoids touching saves, dylibs, plists, etc.
    if (![[relative lowercaseString] hasSuffix:@".xnb"]) return nil;

    NSString *customRoot = SVCustomContentRoot();
    NSString *custom = [[customRoot stringByAppendingPathComponent:relative] stringByStandardizingPath];
    return custom;
}

static const char *SVRedirectPath(const char *path, char *buffer, size_t bufferSize, const char *apiName) {
    if (!path || bufferSize == 0) return path;
    @autoreleasepool {
        NSString *original = [NSString stringWithUTF8String:path];
        NSString *custom = SVCustomPathForOriginal(original);
        if (custom.length == 0) return path;
        if (!SVFileExists(custom)) {
            // Log misses only when the request targets a custom-looking resource, to keep logs readable.
            NSString *lowerOriginal = [original lowercaseString];
            if ([lowerOriginal containsString:@"custom"] || [lowerOriginal containsString:@"wind"] || [lowerOriginal containsString:@"valley"] || [lowerOriginal containsString:@"panorama"] || [lowerOriginal containsString:@"manifest"] || [lowerOriginal containsString:@"hash"]) {
                SVLog(@"%@ miss: %@ -> %@", [NSString stringWithUTF8String:apiName], original, custom);
            }
            return path;
        }
        const char *utf8 = [custom fileSystemRepresentation];
        if (strlen(utf8) + 1 > bufferSize) {
            SVLog(@"%@ redirect path too long: %@", [NSString stringWithUTF8String:apiName], custom);
            return path;
        }
        strcpy(buffer, utf8);
        SVLog(@"%@ redirect: %@ -> %@", [NSString stringWithUTF8String:apiName], original, custom);
        return buffer;
    }
}

static int hook_open(const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "open");
    if (oflag & O_CREAT) return orig_open(target, oflag, mode);
    return orig_open(target, oflag);
}

static int hook_openat(int fd, const char *path, int oflag, ...) {
    mode_t mode = 0;
    if (oflag & O_CREAT) {
        va_list args;
        va_start(args, oflag);
        mode = (mode_t)va_arg(args, int);
        va_end(args);
    }
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "openat");
    if (oflag & O_CREAT) return orig_openat(fd, target, oflag, mode);
    return orig_openat(fd, target, oflag);
}

static FILE *hook_fopen(const char *path, const char *mode) {
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "fopen");
    return orig_fopen(target, mode);
}

static int hook_access(const char *path, int mode) {
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "access");
    return orig_access(target, mode);
}

static int hook_stat(const char *path, struct stat *buf) {
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "stat");
    return orig_stat(target, buf);
}

static int hook_lstat(const char *path, struct stat *buf) {
    char redirected[4096];
    const char *target = SVRedirectPath(path, redirected, sizeof(redirected), "lstat");
    return orig_lstat(target, buf);
}

static void SVWriteReadmeToDocuments(void) {
    NSString *path = [SVDocumentsPath() stringByAppendingPathComponent:@"CustomContent_使用说明.txt"];
    NSString *text = @
    "星露谷 iOS XNB 重定向插件\n"
    "==========================\n\n"
    "把新增或覆盖的 XNB 放到 Documents/CustomContent 下，目录结构要对应 Content。\n\n"
    "示例：\n"
    "游戏请求 Content/Maps/wind_valley_tiles.xnb\n"
    "你应放置 Documents/CustomContent/Maps/wind_valley_tiles.xnb\n\n"
    "游戏请求 Content/Buildings/Wind Valley Barn.xnb\n"
    "你应放置 Documents/CustomContent/Buildings/Wind Valley Barn.xnb\n\n"
    "注意：\n"
    "1. 地图内部引用通常不要带 .xnb 或 .png。\n"
    "2. 路径大小写要完全一致。\n"
    "3. 使用 /，不要使用反斜杠。\n"
    "4. 日志文件：Documents/sv_xnb_redirect.log\n";
    if (!SVFileExists(path)) {
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void SVXnbRedirectMain(void) {
    @autoreleasepool {
        SVLog(@"SVXnbRedirectPlugin loaded");
        SVLog(@"bundle=%@", [[NSBundle mainBundle] bundlePath]);
        SVLog(@"documents=%@", SVDocumentsPath());
        SVWriteReadmeToDocuments();
        SVLogImportantFiles();
        SVScheduleManifestPatches();

        struct rebinding binds[] = {
            {"open", (void *)hook_open, (void **)&orig_open},
            {"openat", (void *)hook_openat, (void **)&orig_openat},
            {"fopen", (void *)hook_fopen, (void **)&orig_fopen},
            {"access", (void *)hook_access, (void **)&orig_access},
            {"stat", (void *)hook_stat, (void **)&orig_stat},
            {"lstat", (void *)hook_lstat, (void **)&orig_lstat},
        };
        int result = rebind_symbols(binds, sizeof(binds) / sizeof(binds[0]));
        SVLog(@"fishhook rebind result=%d", result);
    }
}
