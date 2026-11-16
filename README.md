# VoiceBooks · macOS 桌面版（有声书）

原生 macOS 有声书应用（Swift + SwiftUI），源自「有声书」的产品设计：

**导入 EPUB → 分句建索引 → 离线 TTS 逐句合成朗读（sherpa-onnx）→ 断点续播与书库管理。**

- 本地优先：书籍原文件、正文、封面、句索引、播放进度和 TTS 模型全部保存在本机
- 完全离线合成：sherpa-onnx（VITS / Matcha / Kokoro / Kitten），模型按需下载、可切换音色
- 流式播放：边合成边输出，后台预加载后续句子，减少句间停顿
- 通用二进制：`arm64` + `x86_64`（Apple Silicon 与 Intel）

## 功能一览

### 书库

- 本地多选导入 EPUB；通过 `http/https` 直链从 URL 导入（地址需包含 `.epub`）
- 按文件 MD5 去重，重复书籍自动跳过
- 导入进度实时轮询（下载 / 解析 / 分句 / 建索引），失败可重试
- 排序：按上传时间或最近播放，支持正序 / 倒序，选择会持久化
- 多选批量删除、单本删除；删除时同步清理磁盘文件
- 书籍详情：封面、摘要、出版社、出版时间、语言、ISBN、分类、格式、句数、来源链接
- 刷新元数据、复制书籍信息到剪贴板
- 设置页可「重建书库」：清理重复索引与元数据后重新扫描 `data/books/` 并完整重建

### 播放

- 播放页三个分页：封面 / 字幕 / 书籍信息
- 字幕字号可在 12–48 pt 之间调节，设置会持久化
- 播放 / 暂停、上一句 / 下一句、停止；出错时可一键重试
- 倍速：0.5x、0.75x、1.0x、1.25x、1.5x、2.0x、2.5x、3.0x
- 睡眠定时：15 / 30 / 60 分钟、播完本书、自定义 1–600 分钟，支持倒计时显示
- 断点续播：句子级进度 + 句内毫秒位置；退出应用后重新启动可自动恢复上次播放
- 逐句预加载：默认向前预取 12 句文本与音频，并优先保证下一句就绪
- 播放时可选保持屏幕常亮（`ProcessInfo` 活动断言）
- 键盘快捷键：`空格` 播放 / 暂停，`⌘←` 上一句，`⌘→` 下一句

### TTS 引擎与模型管理

- 内置 52 个 sherpa-onnx 模型，按 VITS / Matcha / Kokoro / Kitten 四类引擎组织
- 语言筛选与分组：中文、中英双语、粤语、英文、德语、法语、西班牙语、葡萄牙语、俄语、韩语、越南语、泰语、土耳其语、波斯语、孟加拉语
- 模型下载：官方 GitHub Release 直连，或配置自建镜像加速；显示下载进度，失败可重试
- 中断恢复：启动时自动清理未完成的下载并标记为失败
- 已下载模型支持试听、删除、设为默认
- 多音色模型支持选择 speaker（0 起始，超过 10 个音色时改为数字输入）
- 试听会记录基准数据：合成耗时、音频时长、RTF、采样率
- 「选为默认」采用草稿机制，点击底部「确认应用」后才加载并切换引擎；切换期间会暂停播放、屏蔽设置操作
- 可设置模型镜像根地址，留空则仅使用官方源

### 启动与异常恢复

- 启动时自动修复异常超长的文本列（`healOversizedBookRows`）
- 预热默认 TTS 模型，减少首次播放等待
- 检测书库 / SQLite / 文件系统异常时弹出提示，可跳转设置页重建书库
- 退出时主动收敛 Sherpa / onnxruntime 原生线程，避免退出崩溃
- 播放会话写入 `playback_session.txt`，应用重启后可恢复

## 环境要求

- macOS 13.0+（Ventura）
- Xcode（首次使用需同意许可）：`sudo xcodebuild -license accept`
- 首次构建需联网，通过 Swift Package Manager 解析依赖：
  - `sherpa-onnx` `1.13.8`（含 macOS xcframework）
  - `onnxruntime-libs` `1.28.2`
- 运行时下载 TTS 模型需要网络；本地推理不需要网络

## 构建与运行

```bash
# 开发运行：Xcode 打开工程，选择 VoiceBooks scheme 后运行
open VoiceBooks.xcodeproj

# 单元测试（61 个 XCTest）
xcodebuild -project VoiceBooks.xcodeproj -scheme VoiceBooks \
  -destination 'platform=macOS' test

# 构建 Universal .app（Release，输出 dist/VoiceBooks.app）
bash scripts/build-universal.sh
```

产物：`dist/VoiceBooks.app`，包含 `arm64 + x86_64` 两种架构。

构建脚本会额外处理 onnxruntime xcframework 中畸形自引用符号链接，移除后以 ad-hoc 方式重新签名，避免 `codesign --deep` 报错。

> 历史说明：本项目已从 Kotlin + Compose Multiplatform + Gradle 迁移为原生 SwiftUI，旧工程已移除。数据库 schema 与 `UserDefaults` 键名延续旧版，便于数据兼容。

## 使用说明

1. 打开「设置 → TTS 引擎管理」，下载任意模型并「选为默认」，再点击底部「确认应用」。
2. 回到书库，点击 `+` 选择本地 EPUB，或粘贴 EPUB 直链导入。
3. 导入完成后点击「开始播放」；播放页可切换字幕、调节字号、倍速和睡眠定时。
4. 若下载缓慢，可在「设置 → TTS 引擎管理 → 模型镜像地址」填入自建镜像根地址。

未下载任何模型时无法播放，应用会提示前往设置下载。

### 推荐模型

| 场景 | 模型 | 说明 |
|---|---|---|
| 中文女声 | `vits-piper-zh_CN-xiao_ya-medium` | 体积小、速度快，日常推荐 |
| 中文男声 | `vits-piper-zh_CN-chaowen-medium` | 与女声同系列 |
| 中文多音色 | `vits-icefall-zh-aishell3` | 174 个 speaker |
| 中英双语 | `matcha-icefall-zh-en` | Matcha，CPU 优化，需自动下载声码器 |
| 中英双语 | `vits-melo-tts-zh_en` | VITS，流式合成 |
| 英文男声 | `vits-piper-en_US-lessac-medium` | 经典 Piper 英文音色 |
| 英语多语种 | `kokoro-multi-lang-v1_1` | 103 个 speaker，批量合成 |

## TTS 模型体系

模型目录定义在 `VoiceBooks/TTS/BuiltInTtsModels.swift`，当前共 **52 个模型**。

| 引擎族 | 数量 | 合成方式 | 说明 |
|---|---:|---|---|
| VITS | 47 | 流式回调优先 | 覆盖中、英、粤、德、法、西、葡、俄、韩、越、泰、土、波斯、孟加拉等语言 |
| Matcha | 1 | 流式回调 | `matcha-icefall-zh-en`，需额外下载 `vocos-16khz-univ.onnx` 声码器 |
| Kokoro | 2 | 批量合成 | 多语种 / 英文，声学质量较好，首句延迟较高 |
| Kitten | 2 | 批量合成 | Nano / Mini 英文小模型，体积小、启动快 |

下载机制：

- 官方源：`https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/<modelId>.tar.bz2`
- Matcha 声码器：`https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos-16khz-univ.onnx`
- 镜像源：应用将下载 `<镜像根地址>/<modelId>.tar.bz2`；附属文件按文件名平铺在镜像根目录下
- 下载后使用系统 `tar -xjf` 解包到 `data/tts_models/<modelId>/`，并校验模型文件布局
- 下载失败或文件不完整会清理临时目录并标记状态，避免半成品占位

### 模型镜像脚本

`scripts/tts-model-mirror.sh` 会解析 Swift 模型目录，下载全部模型（含声码器）并通过 `rsync` 同步到自建服务器：

```bash
# 查看将要同步的文件
scripts/tts-model-mirror.sh --list

# 下载到本地缓存并上传到镜像服务器
scripts/tts-model-mirror.sh \
  -H es.galaxyrover.com -u root \
  -d /root/src.galaxyrover.com/statics/mirrors

# 其他选项
#   -c <path>        本地缓存目录（默认 build/tts-mirror-cache）
#   -f <regex>       只处理匹配的模型文件
#   --download-only  仅下载
#   --upload-only    仅上传
#   --force          已存在也重新下载
#   --dry-run        只演示 rsync，不实际传输
```

前置条件：已配置 SSH 公钥免密登录（`ssh-copy-id <user>@<host>`），并安装 `curl`、`rsync`、`ssh`、`python3`。

## 技术栈与架构

| 层 | 实现 |
|---|---|
| UI | SwiftUI：`NavigationSplitView` 侧边栏 + `HSplitView` 书库三栏布局 |
| 状态管理 | `ObservableObject` / `@Published`；全局 `PlaybackController` 单例 + `AppNotifier` 轻提示 |
| 数据库 | 系统 `libsqlite3`，`actor` 串行封装，`sqlite3_busy_timeout` 5 秒 |
| 设置 | `UserDefaults`（键名与旧版 Datastore 对齐） |
| TTS | sherpa-onnx 1.13.8（Swift API + xcframework）；专用串行线程管理原生引擎 |
| 音频输出 | `AVAudioEngine` + `AVAudioSourceNode` + 线程安全 Float 环形缓冲 |
| 音频处理 | 逐块 RMS 归一化 + 峰值限制 + 5ms 增益渐变 |
| EPUB 解析 | 系统 `ditto` 解包 + `XMLDocument` 解析 container/OPF + 轻量 HTML→文本 |
| 文件选择 / 剪贴板 | `NSOpenPanel` / `NSPasteboard` |
| 模型下载 | `URLSession` 流式下载 + 系统 `tar` 解包 |
| 屏幕常亮 | `ProcessInfo.beginActivity(.idleDisplaySleepDisabled)` |
| 并发模型 | Swift Concurrency（`Task` / `actor`）+ `NSLock` 保护实时播放状态 |

### 导入管线

1. 本地文件先复制到 `cache/import_incoming/` 暂存
2. 计算 MD5，查询 `books.contentMd5` 唯一索引去重
3. 将 EPUB 复制到 `data/books/<bookId>.epub`，写入 `pending` 记录
4. `ditto -x -k` 解包，读取 `META-INF/container.xml` 与 OPF
5. 解析书名、作者、摘要、出版社、日期、语言、ISBN、分类和封面
6. 按 spine 顺序提取正文 HTML → 纯文本，写入 `data/text/<bookId>.txt`
7. 按中英文标点分句，记录 UTF-8 字节偏移与 120 字预览
8. 每 500 条批量写入 `sentence_index`，进度更新到 100%，状态置为 `completed`

### 播放管线

1. 读取书籍句索引与 `playback_progress`
2. 按字节偏移用 `FileHandle` 精准读取当前句
3. 根据当前模型语言适配文本：纯中文模型剥离拉丁词，纯英文模型剥离 CJK
4. 长句按 400 字符切块，优先在次级标点处断开
5. 在专用 Sherpa 线程上流式合成；Kokoro / Kitten 自动回退到批量合成
6. 每个音频块做 RMS 归一化和峰值限制后写入环形缓冲
7. `AVAudioSourceNode` 渲染回调实时取帧播放
8. 以 20ms 轮询播放头，更新句内进度并持久化
9. 后台预加载后续 12 句文本与音频；暂停、跳句、切模型时统一作废旧任务

### 数据目录

```
~/Library/Application Support/com.dafei.voicebook/
  voicebook.db                    # SQLite：books / sentence_index / playback_progress
                                  #        / tts_models / tts_model_benchmarks
  playback_session.txt            # 上次播放书籍与是否自动恢复
  data/
    books/                        # <bookId>.epub 原始文件
    text/                         # <bookId>.txt 提取后的正文
    covers/                       # <bookId>.jpg 封面
    tts_models/<modelId>/         # 解包后的 sherpa-onnx 模型
  cache/
    import_incoming/              # 导入暂存文件
```

## 目录结构

```
VoiceBooks.xcodeproj            # Xcode 工程（文件系统同步组）
VoiceBooks/
  App/                          # VoiceBooksApp / AppDelegate / AppServices / AppNotifier
  Models/                       # Book / AppSettings / 导入与播放模型 / 启动异常
  Data/                         # SQLiteDatabase、AppDatabase、BookStore、TtsStore、
                                # FileStorage、Paths、PlaybackSessionStore
  Import/                       # EpubParser、HtmlTextExtractor、SentenceSplitter、
                                # EbookDownloader、EbookUrlHelper、ImportPipeline
  TTS/                          # SherpaTtsEngine、SherpaInitCoordinator、模型目录、
                                # 下载、资产解析、语言分组、文本适配/切块、
                                # 试听基准、PcmPlayer、TtsRepository
  Playback/                     # PlaybackEngine、PlaybackController、PlaybackLogic、
                                # PlaybackWakeLock
  Repositories/                 # BookRepository / TtsRepository
  ViewModels/                   # LibraryViewModel / SettingsViewModel
  Views/                        # RootView、LibraryScreen、BookDetailColumn、
                                # PlayerView、SettingsScreen、Components
  Utils/                        # Log、Formatters、MD5Hasher、ProgressFormat、StringHelpers
  Assets.xcassets               # AppIcon / AccentColor
Support/                        # Info.plist / VoiceBooks.entitlements
VoiceBooksTests/                # XCTest 单元测试
scripts/                        # build-universal.sh / render-appicon.sh /
                                # tts-model-mirror.sh / appicon/AppIcon.svg
.github/workflows/              # build-macos.yml：测试 + Universal 打包 + artifact
```

## 测试与持续集成

`VoiceBooksTests` 共 61 个测试，覆盖：

- 分句规则：中文标点、小数不误切、Emoji / 混合文本、UTF-8 字节偏移、120 字预览上限、大文本性能
- 播放逻辑：播放头等待超时策略、句内位置边界与容差、暂停 / 恢复竞态保护
- 音频增益：目标 RMS 归一化、短块复用增益、静音块、尾部静音、峰值限制
- 文本处理：中文 / 英文 / 双语模型文本适配、长文本切块
- 模型目录：无 int8 残留、Matcha 声码器校验、镜像附属文件 URL
- 工具：MD5 已知向量、URL 校验与文件名解析、进度格式化

CI（`.github/workflows/build-macos.yml`）在推送 `v*` 标签或手动触发时：

1. 运行全部单元测试
2. 构建 Universal `.app`
3. 用 `lipo` 验证双架构
4. 打包为 `VoiceBooks-macos-universal.zip` 并上传 artifact

## 已知限制与注意事项

- **仅支持 EPUB**，不支持 TXT、MOBI、AZW3 等格式；URL 导入要求链接路径含 `.epub`
- 不处理 DRM 加密电子书
- 首次加载模型和首次合成存在秒级延迟；Kokoro / Kitten 为批量合成，首句等待更明显
- 模型体积从约 30 MB 到 350 MB，下载需预留磁盘空间
- `build-universal.sh` 产物为 **ad-hoc 签名且未公证**，首次打开可能需在「系统设置 → 隐私与安全性」中允许
- 应用未启用 App Sandbox，仅声明网络客户端权限，以便直接读写应用支持目录并启动系统 `ditto` / `tar`
- Intel 机器上合成速度明显低于 Apple Silicon，建议选用体积较小的 Piper / Matcha 模型
- 模型本身遵循 sherpa-onnx 上游及各模型发布页的许可；商用前请自行确认

## 许可

AGPL-3.0（与上游一致），见 [LICENSE](LICENSE)。
