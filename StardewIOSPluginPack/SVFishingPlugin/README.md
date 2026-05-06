# 星露谷 iOS 钓鱼插件源码包

这个包用于全能签注入插件测试。当前 Windows 环境没有 iPhoneOS SDK / Xcode，不能直接编译出可注入的 `dylib`，所以这里提供的是可在 macOS/Xcode 或 Theos 环境编译的源码。

## 作用

- 插件加载后写日志到：`Documents/sv_fishing_plugin.log`
- 输出当前加载的镜像、主程序基址等信息
- 生成提示文件：`Documents/sv_fishing_hints.txt`
- 支持通过配置文件按 native 偏移打补丁：`Documents/sv_fishing_patch.txt`

## 为什么不是直接成品跳过钓鱼

iOS 1.6.15 是 `.NET iOS AOT`。`StardewValley.dll` 里只有元数据，真正代码在 `StardewValley` Mach-O 主程序中。

因此不能像 PC 那样直接改 DLL IL。要跳过钓鱼，需要先在 IDA / Hopper / Ghidra 里定位 `BobberBar` 或 `FishingRod` 的 native AOT 地址，再用本插件写入 ARM64 补丁。

## 已确认的钓鱼相关元数据名

- `BobberBar`
- `FishingRod`
- `pullFishFromWater`
- `doneFishing`
- `distanceFromCatching`
- `bobberPosition`
- `fishPosition`
- `treasurePosition`
- `treasureCaught`
- `whichFish`

## 编译示例

在 macOS 上：

```bash
xcrun --sdk iphoneos clang++ -arch arm64 -dynamiclib \
  -isysroot $(xcrun --sdk iphoneos --show-sdk-path) \
  -framework Foundation -framework UIKit \
  -fobjc-arc SVFishingPlugin.mm \
  -o SVFishingPlugin.dylib
```

然后用全能签导入 `SVFishingPlugin.dylib`。

## 使用方法

1. 编译 `SVFishingPlugin.dylib`
2. 全能签签名时导入插件
3. 启动游戏
4. 查看 App 的 Documents 目录：
   - `sv_fishing_plugin.log`
   - `sv_fishing_hints.txt`
5. 用 IDA/Hopper/Ghidra 找到钓鱼 native patch 偏移
6. 在 Documents 创建：

```text
sv_fishing_patch.txt
```

格式：

```text
# offset_hex=arm64_bytes_hex
0x123456=C0035FD6
```

常见 ARM64 指令：

```text
RET              C0035FD6
MOV W0,#1; RET   20008052C0035FD6
MOV W0,#0; RET   00008052C0035FD6
```

注意：偏移是相对 `StardewValley` 主程序 Mach-O header 的偏移，不是 DLL offset。

## 下一步建议

先确认插件能加载并写日志。确认后，再用日志里的主程序基址配合反汇编定位 `BobberBar.update` 或 `FishingRod.pullFishFromWater`。

最稳的钓鱼修改点不是完全跳过 UI，而是让钓鱼小游戏每帧自动成功，例如：

- `distanceFromCatching` 强制满
- 成功分支强制成立
- 鱼位置强制贴住绿条
- 失败扣进度逻辑跳过
