# 星露谷 iOS 新增 XNB 重定向插件

这个插件用于 iOS 版星露谷 1.6.15 的新增 XNB 资源加载。

## 功能

插件做两件事：

1. 启动后扫描 `Documents/CustomContent/**/*.xnb`，把对应资源名动态加入游戏的 `LocalizedContentManager._manifest`，用于绕过 1.6.15 的新增资源检测。
2. 当游戏访问：

```text
StardewValley.app/Content/Maps/xxx.xnb
```

插件会先检查：

```text
Documents/CustomContent/Maps/xxx.xnb
```

如果存在，就重定向读取自定义文件；不存在则走原始路径。

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
