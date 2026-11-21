## 大白话：Unlicense 许可证——你用、改、卖，换命名，你开心就好！

##### ”社区的核心精神“
```js
——如果每份公开的代码都要附加一堆条条框框，劝退很多人主动分享。

——“代码能用、能被改进” 比 “内容归属” 重要得多。
```
🔴 <font color="red">遵循 [Unlicense 许可证](https://unlicense.org/#unlicensed-free-software)</font>

🟢 <font color="green">遵循 [早期黑客文化](https://en.wikipedia.org/wiki/Hacker_culture) 是"无限制"的</font>

🔵 <font color="blue">[早期 UNIX](https://en.wikipedia.org/wiki/History_of_Unix) 是"无限制"的</font>


# 工作流
```js

name: Build IPA

on:
  push:
    branches: [ "main" ]
  workflow_dispatch:

jobs:
  build:
    runs-on: macos-15
    steps:
     - uses: actions/checkout@v3
     - name: Compile
       run: make
     
     - name: Upload artifact
       uses: actions/upload-artifact@v4
       with:
        name: APP
        path: APP.ipa
```

# make文件
```js
BASEDIR = $(shell pwd)
BUILD_DIR = $(BASEDIR)/build
INSTALL_DIR = $(BUILD_DIR)/install
PROJECT = $(BASEDIR)/APP.xcodeproj
SCHEME = APP
CONFIGURATION = Release
SDK = iphoneos
DERIVED_DATA_PATH = $(BUILD_DIR)

all: ipa

# 依赖关系
ipa: $(PROJECT)
	mkdir -p ./build
	xcodebuild -jobs 8 -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) -sdk $(SDK) -derivedDataPath $(DERIVED_DATA_PATH) CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO DSTROOT=$(INSTALL_DIR)
	rm -rf ./build/APP.ipa
	rm -rf ./build/Payload
	mkdir -p ./build/Payload
	cp -rv ./build/Build/Products/Release-iphoneos/APP.app ./build/Payload
	cd ./build && zip -r APP.ipa Payload
	mv ./build/APP.ipa ./

# 强制重新构建
force: clean ipa

clean:
	rm -rf ./build
	rm -rf ./APP.ipa

.PHONY: all ipa clean force

```

![Preview](./X/14.png)
![Preview](./X/13.png)

# 本地编译 APP.ipa 方法
## 终端: cd APP这文件夹
## 终端: make

---

# 下载管线（多连接分段 + 断点续传）

IPA 下载核心在 `APP/Services/Download/`：

```
PurchaseManager (所有权/购买检查——响应自带下载元数据，直接复用)
        │
UnifiedDownloadManager (队列编排 / 版本解析 / 进度映射)
        │
AppStoreDownloadManager (编排/状态/进度节流/EMA 平滑)
        │
SegmentedIPADownloader (分段下载器)
        ├─ 探测: Range: bytes=0-0 → 206 + Content-Range → 分段模式
        ├─ 分段: 每段独立 URLSession（强制多条 TCP 连接，绕开 HTTP/2 单连接复用）
        ├─ 回退: 服务器不支持 Range → 单流顺序下载（与旧行为一致）
        └─ 断点: .segresume JSON 持久化段进度，重试/重启后续传
```

- **点击到开始传输**：所有权/购买检查（download-dispatch 端点）的响应本身含完整下载元数据，
  直接复用跳过版本解析与取地址——典型已购应用从 4 个串行往返降到 2 个
  （`PurchaseResult.downloadSongList` → `downloadApp(prefetchedSongList:)`）；
  用户显式指定的旧版本不复用（预取的是最新版本数据）
- **暂停/继续**：下载卡片按钮。进程内 → 恢复挂起的任务（`hasSuspendedTasks` 精确判定）；
  重启后 → 走 `.segresume` 断点续传
- **速度显示**：EMA 平滑（α=0.25），多连接聚合速度不再每 100ms 跳动；
  续传恢复首帧只记基线不计速，避免虚假高速
- **调参**：`SegmentedIPADownloader.swift` 顶部常量 —— `maxSegments = 6`（并行段数）、`minSegmentSize = 32MB`、`maxSegmentRetries = 2`
- **断点续传校验**：版本 / URL / 总大小 / 临时文件大小 / 段边界，任一不符自动丢弃断点全新下载；单流回退模式不续传
- **文件生命周期**：成功删断点；失败/取消保留（重试续传）；删除下载请求时经 `purgeDownloadArtifacts` 清理
- **真机日志**：`[SegmentedDownloader] <id> start, size=..., range=true, segments=N`（分段生效）；`resume=true, resumedBytes=...`（续传生效）
- **正确性**：完成后仍做大小校验 + 整文件 MD5 校验，通过后才注入 sinf / iTunesMetadata
- **回归测试**：`cd tools/download-harness && ./run.sh` 一键跑全部场景（分段/回退/取消/暂停/续传/进程被杀/断点损坏，本地 Range 服务器模拟 CDN）。改完下载器代码后跑一遍即可回归

---


<!-- 左右排列 -->
<div style="display: flex; justify-content: space-evenly; align-items: center; width: 100%; overflow: auto; gap: 40px; padding: 10px 0;">
    <img src="./X/1.PNG" alt="Preview" width="300" />
    <img src="./X/2.PNG" alt="Preview" width="300" />
    <img src="./X/3.PNG" alt="Preview" width="300" />
    <img src="./X/4.PNG" alt="Preview" width="300" />
    <img src="./X/5.PNG" alt="Preview" width="300" />
    <img src="./X/6.PNG" alt="Preview" width="300" />
</div>

<hr style="border: 1px solid #ccc; margin: 20px 0;">

---

<!-- 左右排列 -->
<div style="display: flex; justify-content: space-evenly; align-items: center; width: 100%; overflow: auto; gap: 40px; padding: 10px 0;">
    <img src="./X/7.PNG" alt="Preview" width="300" />
    <img src="./X/8.PNG" alt="Preview" width="300" />
    <img src="./X/9.PNG" alt="Preview" width="300" />
    <img src="./X/10.PNG" alt="Preview" width="300" />
    <img src="./X/11.PNG" alt="Preview" width="300" />
    <img src="./X/12.PNG" alt="Preview" width="300" />
</div>

<hr style="border: 1px solid #ccc; margin: 20px 0;">