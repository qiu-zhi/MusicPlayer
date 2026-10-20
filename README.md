# Music Player

基于 Qt 6 / QML 的本地音乐播放器。Windows 与 Android 已测试；Linux、macOS、HarmonyOS 理论上支持，尚未测试。

<p align="center">
  <img src="docs/screenshots/music1.gif" width="45%" alt="播放页">
  <img src="docs/screenshots/music2.gif" width="45%" alt="歌词页">
</p>

## 功能

- 播放本地音频，支持 mp3 / flac / wav / m4a / aac / ogg / wma / ape / opus（目前只实测过 mp3）
- 添加单曲，或递归扫描整个文件夹，重复曲目自动跳过
- 自动加载与音频同名的 `.lrc` 歌词，支持 GBK / GB18030 编码
- 三档播放模式：列表循环、单曲循环、随机
- 收藏歌曲单独成列表，播放范围跟随来源列表
- 输出设备可选自动（蓝牙优先）或手动指定（仅 Windows，见「已知限制」）
- 音乐库管理支持全选与批量删除
- Android 上可从文件管理器用本播放器打开音频
- 播放前校验文件是否仍可访问，被外部删除的曲目会提示并移出列表

## 构建

### 依赖

- Qt 6.8 或更高版本，需要 `Core`、`Gui`、`Qml`、`Quick`、`QuickControls2`、`Multimedia`、`Core5Compat`、`Concurrent`
- CMake 3.16 或更高版本

`Core5Compat` 是必需的：`Qt5Compat.GraphicalEffects` 与歌词的 GBK 解码都依赖它。`Concurrent` 用于把文件夹扫描放到工作线程。`SafeArea`（系统栏避让）从 Qt 6.8 才提供，所以最低版本是 6.8。

### Windows

```bash
cmake -S . -B build/win64 -G Ninja -DCMAKE_PREFIX_PATH="<Qt安装目录>/6.12.0/mingw_64"
cmake --build build/win64
```

也可以用 Qt Creator 打开 `CMakeLists.txt`，选好 Kit 后构建。

### Android

用 Qt Creator 配置 Android Kit 后构建。发布包需要用自己的 keystore 签名，先 `zipalign` 对齐，再 `apksigner sign`。

## 使用

1. 启动后点空态里的「去添加音乐」，或从右上角菜单选择「添加单曲」「扫描文件夹」导入歌曲
2. 播放页点击歌词文字进入歌词页，点击任意一行可跳转到该时间点
3. 控制栏的列表按钮打开播放列表，可在「全部」和「我喜欢的」之间切换，也可在此管理曲库
4. 右上角菜单还可以切换输出设备（仅 Windows）、查看版本信息

Android 上文件读取权限随选择器一并申请，重启后依然可用。

## 项目结构

```
MusicPlayer/
├── CMakeLists.txt          # 构建配置
├── main.cpp                # 入口，注入 folderScanner / nativePlayer / fileOpenRelay / appVersion
├── folderScanner.cpp/.h    # 文件夹扫描、content:// 查询、歌词读取、文件失效检测
├── nativeaudioplayer.cpp/.h # 安卓原生播放器的 Qt 封装（JNI 转发 + 定时轮询状态）
├── Main.qml                # 主界面
├── components/             # 20 个 QML 组件
├── assets/                 # SVG 图标、唱机素材、应用图标
├── android/                # AndroidManifest、图标，以及 src/ 下的原生播放服务
├── tools/                  # 开发期验证脚本
└── keystore/               # 签名密钥，不入库
```

## 技术栈

- 界面全部用 QML；C++ 只负责系统桥（`FolderScanner`、`NativeAudioPlayer`）与启动时的上下文注入
- Qt Quick Controls 2，使用 Basic 样式
- 播放分两条链路，由 `PlaybackEngine.qml` 的 `useNative` 分派：
  Windows 用 Qt Multimedia 的 `QMediaPlayer`；Android 用系统原生 `MediaPlayer`
  （`nativeaudioplayer` + `android/src/PlaybackService.java`）
- 桌面与 Android 共用同一套 QML，路径差异集中在 `FolderScanner`（桌面用 `QDir`，Android 用 SAF）
- 播放模式与输出档位（仅 Windows 生效）通过 `Settings` 持久化

## 已知限制

- 没有应用内音量调节，跟随系统音量
- 没有歌曲搜索
- 输出设备选择只对 Windows 开放：Android 没有可供普通应用指定输出设备的公开 API
  （`setPreferredDeviceForStrategy` 是 `@SystemApi`），且播放已交给系统原生播放器，路由由系统决定
