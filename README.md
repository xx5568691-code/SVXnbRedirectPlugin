# 星露谷 iOS 新增 XNB 重定向插件

这个插件用于 iOS 版星露谷 1.6.15 的新增 XNB 资源加载。

## 功能

插件做两件事：

1. 启动后扫描 `Documents/CustomContent/**/*.xnb`，尝试把对应资源名动态加入游戏的 `LocalizedContentManager._manifest`，用于绕过 1.6.15 的新增资源检测。
2. 当游戏访问：

```text
StardewValley.app/Content/Maps/xxx.xnb
```

插件会先检查：

```text
Documents/CustomContent/Maps/xxx.xnb
```

如果存在，就重定向读取自定义文件；不存在则走原始路径。

3. 支持 `Documents/CustomContent/_aliases.txt` 别名映射，用于 AOT 环境下更稳定地加载新增 XNB。

同理支持：

```text
Content/Buildings
Content/Maps
Content/Data
Content/TileSheets
Content/LooseSprites
Content/Characters
Content/Animals
```

本质上只要路径里包含 `/Content/` 且后缀是 `.xnb`，都会按相同目录结构映射到 `Documents/CustomContent/`。

## 放文件示例

游戏请求：

```text
Content/Maps/wind_valley_tiles.xnb
```

你应该放：

```text
Documents/CustomContent/Maps/wind_valley_tiles.xnb
```

游戏请求：

```text
Content/Buildings/Wind Valley Barn.xnb
```

你应该放：

```text
Documents/CustomContent/Buildings/Wind Valley Barn.xnb
```

## 日志

插件加载后会生成：

```text
Documents/sv_xnb_redirect.log
Documents/CustomContent_使用说明.txt
```

如果没有日志，说明 dylib 没有被加载。

正常情况下日志里应该能看到：

```text
SVXnbRedirectPlugin loaded
mono api loaded=yes
manifest patch after ...: added/tried ... asset names
open redirect: ...
```

如果只看到 `redirect`，但没有 `manifest patch` 成功，说明真实文件读取重定向生效了，但新增资源检测还没有被绕过。

当前 iOS 1.6.15 是 .NET iOS AOT 环境时，`mono_*` API 可能不可用；这种情况下插件不能在运行时改 `_manifest`。新增 XNB 要稳定生效，需要把新增文件放进 `StardewValley.app/Content` 对应目录，或另做离线 manifest 补丁；`Documents/CustomContent` 更适合覆盖已有资源。

插件会在日志里输出 XamarinDumper 定位到的关键 AOT 方法运行时地址和入口字节，例如：

```text
AOT method LCM.DoesAssetExist va=0x10177a7b4 runtime=0x... bytes=...
AOT method LCM.LoadImpl va=0x10177a974 runtime=0x... bytes=...
AOT method LCM.PlatformEnsureManifestInitialized va=0x101767d10 runtime=0x... bytes=...
```

这用于全能签注入后的 native hook 验证：先确认地址和入口字节稳定，再考虑 inline hook `DoesAssetExist` / `LoadImpl` / `PlatformEnsureManifestInitialized`。

## 新增 XNB 推荐方式

在 AOT 环境里，新增资源名可能过不了游戏的 manifest 检查。更稳定的做法是：地图里引用一个游戏原本就存在的资源名，然后用 `_aliases.txt` 把这个已登记资源名映射到真实新增 XNB。

示例：

```text
Documents/CustomContent/_aliases.txt
Maps/springobjects=Maps/panorama
```

然后放置：

```text
Documents/CustomContent/Maps/panorama.xnb
```

当游戏读取：

```text
Content/Maps/springobjects.xnb
```

插件实际会读取：

```text
Documents/CustomContent/Maps/panorama.xnb
```

注意：左边的资源名必须是游戏 manifest 已有资源名；右边才是真实新增资源名。

`_aliases.txt` 支持热重载。修改文件后，下次游戏访问 XNB 时插件会重新加载映射，不需要重启游戏。

## 全能签注入测试

1. 注入 `SVXnbRedirectPlugin.dylib` 后启动游戏。
2. 查看 `Documents/sv_xnb_redirect.log`，确认出现 `SVXnbRedirectPlugin loaded`、`fishhook rebind result=0` 和 `AOT method ...`。
3. 在 `Documents/CustomContent/_aliases.txt` 写入映射，例如 `Maps/springobjects=Maps/panorama`。
4. 放置真实文件 `Documents/CustomContent/Maps/panorama.xnb`。
5. 触发地图加载后，日志应出现 `alias redirect`。
6. 如果仍然在 `Could not load ... asset` 前没有任何 `open/stat/access redirect`，说明失败发生在 manifest 检查阶段，需要进一步 hook `DoesAssetExist` 或 `LoadImpl`。

## 编译

macOS：

```bash
xcrun --sdk iphoneos clang++ -arch arm64 -dynamiclib \
  -isysroot "$(xcrun --sdk iphoneos --show-sdk-path)" \
  -miphoneos-version-min=12.0 \
  -framework Foundation -framework UIKit \
  -fobjc-arc SVXnbRedirectPlugin.mm fishhook.c \
  -o SVXnbRedirectPlugin.dylib
```

也可以直接上传本包到 GitHub，使用内置 GitHub Actions 自动编译。

## 注意

1. 地图内部引用 tilesheet 时，建议写 `Maps/xxx`，不要写 `.xnb` 或 `.png`。
2. 路径大小写必须一致。
3. 不要使用反斜杠 `\`。
4. 插件会多次重试补 manifest，因为游戏的 `_manifest` 可能在插件加载后才初始化。
5. 如果游戏先通过 `File.Exists/stat/access` 判断文件是否存在，本插件也会重定向这些检查。
6. 插件启动时会自动创建 `Documents/CustomContent` 及常用子目录。
7. `_aliases.txt` 每行一个映射，支持 `=` 或 `->`，例如 `Maps/springobjects=Maps/panorama`。
8. 如果日志停在 `documents=...` 且没有 `fishhook rebind result=...`，说明旧版 fishhook 在当前 iOS 上写只读符号表时崩溃，请使用包含 `vm_protect` 修复的新版源码重新编译。
