# VoiceBooks · macOS 桌面版（有声书）

原生 macOS 桌面应用（Swift + SwiftUI），功能与 Android 版「有声书」保持一致：

**导入 EPUB → 逐句离线 TTS 朗读（sherpa-onnx）→ 断点续播与书库管理。**

- 本地优先：书籍、封面、正文、句索引、TTS 模型均保存在本机
- 离线 TTS：sherpa-onnx（VITS / Kokoro / Kitten），模型按需下载、可切换默认音色
- 通用二进制：`arm64` + `x86_64`（Intel 与 Apple Silicon）

## 功能一览

- **书库**：本地选择 / URL 导入 EPUB、排序（上传时间 / 最近播放，正序 / 倒序）、批量删除、导入进度、失败重试、刷新元数据、复制书籍信息、重建书库
- **播放**：封面 / 字幕 / 书籍信息分页、播放控制、快进快退（10 句）、倍速、睡眠定时（15/30/60 分钟、播完本书、自定义）、断点续播、逐句预加载
- **设置**：播放时保持屏幕常亮、TTS 引擎 / 模型管理（下载、镜像下载、删除、试听、基准、设为默认、音色选择、语言筛选）、重建书库
- **启动恢复**：检测到书库 / 索引异常时提示前往设置页重建

## 环境要求

- macOS 13.0+（Ventura）
- Xcode（首次需同意许可）：`sudo xcodebuild -license accept`
- 首次构建会通过 Swift Package Manager 解析 `sherpa-onnx 1.13.8`（含 macOS xcframework 与 onnxruntime）

## 构建与运行

```bash
# 运行（开发）
open VoiceBooks.xcodeproj    # 选择 VoiceBooks scheme 运行

# 单元测试
xcodebuild -project VoiceBooks.xcodeproj -scheme VoiceBooks \
  -destination 'platform=macOS' test

# 构建 Universal .app（输出到 dist/VoiceBooks.app）
bash scripts/build-universal.sh
```

产物：`dist/VoiceBooks.app`（`arm64 + x86_64`）。

> 说明：本项目已从 Kotlin + Compose Multiplatform 迁移为原生 SwiftUI。
> 旧的 Kotlin/Gradle 源码仍保留在磁盘上作为参考（已在 `.gitignore` 中忽略），不再参与构建。

## 使用说明

- 播放前需在「设置 → TTS 引擎管理」中**下载并设为默认**离线模型。
- 中文推荐：`vits-piper-zh_CN-xiao_ya-medium`（高品质）或 int8 版本（轻量）。
- 英文推荐：`vits-piper-en_US-lessac-medium`。
- 未下载模型时无法播放，会提示前往设置下载。

## 技术栈与架构

| 层 | 实现 |
|---|---|
| UI | SwiftUI（`NavigationSplitView` 侧边栏 + `HSplitView` 三栏书库） |
| 数据库 | 系统 `libsqlite3`（actor 封装，schema 与旧版一致） |
| 设置 | `UserDefaults`（键与旧版 Datastore 一致） |
| TTS | sherpa-onnx 1.13.8（Swift API + xcframework） |
| 音频输出 | `AVAudioEngine` + `AVAudioSourceNode`（流式 PCM） |
| EPUB 解析 | 系统 `ditto` 解包 + `XMLDocument` 解析 OPF + 轻量 HTML→文本 |
| 文件选择 / 剪贴板 | `NSOpenPanel` / `NSPasteboard` |
| 模型下载 | `URLSession` 流式下载 + 系统 `tar` 解包 |

数据目录：`~/Library/Application Support/com.dafei.voicebook/`（`data/`、`voicebook.db`、`tts_models/` 等）。

### 目录结构

```
VoiceBooks.xcodeproj            # Xcode 工程（文件系统同步组）
VoiceBooks/
  App/                          # 入口 / AppServices / AppNotifier
  Models/                       # 数据模型 / AppSettings / 播放状态 / 启动异常
  Data/                         # SQLite / BookStore / TtsStore / FileStorage / 会话
  Import/                       # EPUB 解析 / 分句 / MD5 / 下载 / 导入管线
  TTS/                          # Sherpa 引擎 / 协调器 / 模型目录 / 下载 / 试听 / PCM 播放
  Playback/                     # 播放引擎 / 控制器 / 等待与位置策略 / 屏幕常亮
  Repositories/                 # BookRepository
  ViewModels/                   # 书库 / 设置
  Views/                        # RootView / LibraryScreen / PlayerView / SettingsScreen / Components
  Utils/                        # 日志 / 格式化 / MD5 / 字符串
Support/                        # Info.plist / entitlements
VoiceBooksTests/                # XCTest（纯逻辑移植自旧版单测）
scripts/                        # build-universal / render-appicon
```

## 许可

AGPL-3.0（与上游一致），见 [LICENSE](LICENSE)。
