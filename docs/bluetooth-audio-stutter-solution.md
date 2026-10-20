# Qt 内置播放组件在蓝牙耳机下卡顿：根因分析与解决方案

> 项目：MusicPlayer（Qt 6.12 + QML/C++，Windows / Android 双平台）  
> 日期：2026-10-14 ~ 10-15  
> 状态：已解决并实机验证

---

## 一、问题现象

在 Android 上用蓝牙耳机播放音乐时：

- 播放中出现**持续卡顿**（不是瞬间一下，而是卡住后一直卡）
- **切歌**会触发
- **拖拽进度条**也会触发
- 切一次「输出设备」能暂时恢复
- 扬声器播放**从不卡**
- 部分歌曲特别容易触发（《刻在我心底的名字》几乎必现），其他歌曲很少触发

---

## 二、结论速览

| 项                | 内容                                                                                                                                                    |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **根因**          | Qt 的安卓音频输出缓冲比系统播放器**小一半**，且在采样率与 A2DP 输出匹配时走"直通"，时序抖动无处吸收                                                     |
| **决定性差异**    | 我们 `AAudio` → `AudioOut_D`(PRIMARY)，HAL 缓冲 **21.3 ms**；系统播放器 `AudioTrack + DEEP_BUFFER` → `AudioOut_15`，HAL 缓冲 **42.7 ms**                |
| **Qt 侧能否配置** | **不能**。`bufferSizeInBursts` 是 `constexpr`、`bufferCapacity` 硬编码 `1024`、`QAndroidAudioSink` 未实现 `setBufferSize()`、整个目录无任何环境变量入口 |
| **最终方案**      | Android 侧**改用系统原生 `MediaPlayer`**，与系统播放器同路；Windows 保留 `QMediaPlayer`                                                                 |
| **验证**          | `dumpsys audio` 显示流类型从 `AAudio` 变为 `android.media.MediaPlayer`，卡顿消失                                                                        |

---

## 三、根因分析

### 3.1 我们与系统播放器的实际差异

对比 `dumpsys audio` 中同一副耳机下的音频流：

```
我们：
  AudioPlaybackConfiguration type:AAudio
  Output thread: AudioOut_D        （PRIMARY）
  HAL frame count: 1024            = 21.3 ms

系统播放器（QQ音乐等）：
  AudioPlaybackConfiguration type:android.media.AudioTrack
  AudioAttributes flags: 0xA00     （含 AUDIO_FLAG_DEEP_BUFFER = 0x200）
  Output thread: AudioOut_15       （DEEP_BUFFER）
  HAL frame count: 2048            = 42.7 ms
```

**HAL 缓冲差一倍。** 这是整个问题的物理基础 —— 输出线程必须按时从 HAL 取走数据，取慢了就是 underrun。

### 3.2 为什么只有特定歌曲会卡

对比一首"必卡"的歌与一首"不卡"的歌：

| 歌曲             | 表现   | 采样率       | 码率     | ID3 标签 |
| ---------------- | ------ | ------------ | -------- | -------- |
| 刻在我心底的名字 | **卡** | **48000 Hz** | 320 kbps | 529 KB   |
| AI 生成          | 不卡   | **44100 Hz** | 256 kbps | 1.1 KB   |

而 **A2DP 输出线程固定 48000 Hz**，我们播放时的流也是 48000 Hz。

```
44100 Hz 的源 → 必须经混音器重采样到 48000
                → 重采样路径自带缓冲 → 抖动被抹平 → 不卡

48000 Hz 的源 → 与输出完全匹配 → 直通，中间没有任何缓冲垫
                → 流里的时序抖动直接打在 21.3 ms 的 HAL 余量上 → 卡
```

> **反直觉但可解释**：码率（320 vs 256）不是变量，**采样率是否与 A2DP 直通**才是。

### 3.3 为什么扬声器从不卡

扬声器落在深缓冲输出线程上，HAL 缓冲是几百毫秒量级，21 ms 的抖动完全吸收得掉。只有蓝牙耳机这条路径暴露在极小余量下。

### 3.4 为什么"切一次输出设备"能恢复

`setOutputMode()` → `applyRoute()` → `audio.device = target` 会真正改变设备，触发平台层销毁并重建 audio sink，缓冲被重新填满、抖动计时被重置。

**注意**：这条路径之所以有效，正说明"重建 sink"确实能清掉坏状态 —— 但我们在切歌路径上**重建了 MediaPlayer、却没重建 sink**（见 5.1）。

### 3.5 为什么 dumpsys 数据全部"正常"

排查中最迷惑的一点：卡顿期间系统侧一切正常。

```
Normal mixer raw underrun counters: partial=0 empty=0     ← 零欠载
Threadloop write latency: ave=261ms                        ← 稳定
Standby: no                                                 ← 一直在播
50ms 电平包络：最长连续静音格数 = 0                          ← 数据连续无空洞
```

**原因**：HAL 数据不足时，Android 的蓝牙 HAL **重复上一帧**而不是写静音。因此：

- 欠载计数器不增长
- 电平包络看不到空洞
- 但**听感就是卡顿**

> **教训**：电平包络测不到静音 ≠ 数据没问题。这里它只排除了"写静音"这一种坏法。

---

## 四、Qt 为什么无法配置这个缓冲

逐条源码查证：

```cpp
// ① qaaudiostream.cpp:15  —— 缓冲倍数硬编码
constexpr int bufferSizeInBursts = 3; // Triple buffering
...
AAudioStream_setBufferSizeInFrames(m_stream, burstSize * bufferSizeInBursts);

// ② qandroidaudiosink.cpp:34-36  —— 容量上限硬编码
builder.bufferCapacity = m_nativePeriodFrames
        ? qToUnderlying(*m_nativePeriodFrames)
        : 1024;                    // QMediaPlayer 路径永远是 1024 帧 = 21.3 ms

// ③ QAndroidAudioSink 未实现 setBufferSize()   → QAudioSink::setBufferSize() 在安卓无效

// ④ 整个 src/multimedia/android/ 下 qEnvironmentVariable / qgetenv 零命中
```

**且 Qt 也没有暴露对应 API**：

```cpp
// qaudioplayer.h
Q_PROPERTY(QAudioOutput *audioOutput ...)   // QAudioOutput 只有 setDevice/setVolume/setMuted

// qaudiosink.h:62（另一个类）
void setNativePeriodFrameCount(qsizetype frameCount);   // ← 这个有，但 QAudioOutput 没有
```

> 也就是说：整个 qtmultimedia 里**只有 `QAudioSink` / `QAudioSource` 能调 AAudio 缓冲，  
> 而 `QMediaPlayer` 走的是 `QAudioOutput`，两者之间没有转发。**

---

## 五、尝试过但**失败**的四种方案

这一节是本文最有价值的部分 —— 每种方案失败的原因都不同。

### 5.1 方案一：切歌时"先拆后建"

**做法**：`switchTo()` 改成 `player.stop()` → `player.source = ""` → 再设新 source。

**起因**：原始实现只做 `stop()` 后直接改 source，flinger 日志里新 track 的 `AT::add` 比旧 track 的 `AT::remove` **早 150~300 ms**，两条音频流短暂共存。

**结果**：时序问题确实消失了（日志确认 `AT::remove` 早于 `AT::add` 143 ms），**但卡顿照旧**。

**失败原因**：只重建了 MediaPlayer，**audio sink 沿用旧实例**，坏状态没被清掉。

**这一条暴露了一个隐蔽的陷阱** —— 代码注释里写着：

```
// 切歌：走与「输出设备重建」**完全相同**的链路（stop → 清空 source → 设新 source → play）
```

但实际对比：

| 步骤                                | `applyRoute → rebindAudio` | `switchTo` |
| ----------------------------------- | -------------------------- | ---------- |
| **重设输出设备**                    | `audio.device = target` ✅  | **没有** ❌ |
| 更新 `activeDeviceId`               | ✅                          | 没有       |
| stop / 清 source / 设 source / play | ✅                          | ✅          |

**注释把不完整的实现描述成"完全相同"，直接掩盖了缺陷。** 这个矛盾是用户读代码时发现的。

### 5.2 方案二：切歌时重建 audio sink

**做法**：`player.audioOutput = null` → `player.audioOutput = audio`。

**结果**：无效。

**失败原因**：`QMediaPlayer` 只是**引用** `QAudioOutput`，解绑/重绑并不会销毁其内部的 `QPlatformAudioOutput`。要真正销毁必须重建 `QAudioOutput` 对象本身。

### 5.3 方案三：换后端 `QT_MEDIA_BACKEND=android`

**做法**：`qputenv("QT_MEDIA_BACKEND", "android")`。

**结果**：更糟 —— 整机被打进通话模式。

```
流类型确实变成 android.media.MediaPlayer
但 deviceIds:[2]（扬声器，不是蓝牙）
Actual mode = MODE_IN_COMMUNICATION          ← 整机进入通话态
A2DP 电平包络停止更新                        → 蓝牙彻底没声
```

**失败原因**：Qt 的 android 播放后端用 `AudioTrack` 时调用了 `setMode(MODE_IN_COMMUNICATION)`，这是它为"通话场景"设计的，与音乐播放冲突。

### 5.4 方案四：直接改 Qt 的二进制

既然 Qt 不给配置入口，就改二进制。（备份均为 `<file>.orig`）

**补丁 1：缓冲倍数 3 → 9**

```asm
; qaaudiostream.cpp:165 对应的机器码
原始: 157694: 0b000401   add w1, w0, w0, lsl #1    ; w0 + w0*2 = 3×
修改: 157694: 0b000c01   add w1, w0, w0, lsl #3    ; w0 + w0*8 = 9×
```

**结果**：无效。

**失败原因（关键）**：`setBufferSizeInFrames()` 会被 **capacity** 截断，而 capacity 是 1024 帧 —— 改成 9 倍仍被砍到 1024 帧上限，白改。

**补丁 2：capacity 1024 → 4096**（这才是真正的瓶颈）

```asm
; qandroidaudiosink.cpp:36  `... : 1024;` 对应的机器码
原始: 14ea5c: 52808008   mov w8, #0x400      ; 1024 帧
修改: 14ea5c: 52820008   mov w8, #0x1000     ; 4096 帧（85.3 ms）
```

**结果**：仍无效。

**最终判定**：症状（切歌/seek 后持续卡）与"缓冲不足"的表现不符 —— 若真是缓冲不足，应当表现为欠载/断续，而实测欠载恒为 0。**缓冲小是结构性劣势，但不是这个 bug 的直接病因。**

---

## 六、最终方案：Android 改用系统原生播放

既然应用层无法控制缓冲，就**换到与系统播放器同一条路上**。

### 6.1 核心思路

```
Qt 层：只负责 UI 与业务逻辑
   ↓ JNI（QAndroidJniObject）
Android 层：系统 MediaPlayer + 前台服务
   → 与 QQ音乐 / 系统播放器完全同路（AudioTrack + DEEP_BUFFER）
```

### 6.2 决定性验证

装机后抓 `dumpsys audio`：

```
播放前：type:AAudio                      ← Qt 的音频输出
播放后：type:android.media.MediaPlayer   ← 已换成系统原生播放器
        state:started, sampleRate=44100
        PlaybackService 已作为前台服务启动
```

**"系统里音频流的类型"是骗不了人的。** 卡顿随之消失。

### 6.3 实现要点

**Android 侧（新增）**

| 文件                                                   | 职责                                                                             |
| ------------------------------------------------------ | -------------------------------------------------------------------------------- |
| `android/src/com/quz/musicplayer/PlaybackService.java` | 前台服务 + `android.media.MediaPlayer`；含通知（**避免"切后台就停"的功能倒退**） |
| `android/src/com/quz/musicplayer/AudioBridge.java`     | JNI 入口；`init(Context)` **提前把服务拉起来**                                   |

> ⚠️ **踩坑**：服务是异步创建的，若等第一次播放才 `startForegroundService`，那次调用会落在 `sInstance == null` 上**静默失败**。解决：`init()` 就预启动服务，并在 Qt 侧保留有限次重试兜底。

**Qt 侧（新增）**

| 文件                       | 职责                                                                                                     |
| -------------------------- | -------------------------------------------------------------------------------------------------------- |
| `nativeaudioplayer.h/.cpp` | JNI 转发 + `QTimer` 200 ms 轮询状态（不做反向回调，少一层复杂度）；全部代码包在 `#ifdef Q_OS_ANDROID` 内 |

**QML 侧（改动极小）**

在 `PlaybackEngine.qml` 内部按平台分派，**`Main.qml` 一行没改**：

```qml
readonly property bool useNative: Qt.platform.os === "android"
                                 && typeof nativePlayer !== "undefined"
                                 && nativePlayer.available()
```

- `positionMs` / `durationMs` 用三元运算符取不同来源
- `Connections` 把 `ended` / `errorOccurred` / `positionChanged` / `playingChanged` 桥接过来
- `switchTo` / `play` / `pause` / `stop` / `replay` / `seekToMs` / `onSourceChanged` /  
  `Component.onCompleted` / `onAudioOutputsChanged` / `refreshAudioRoute` 全部加 `if (useNative) return`
- **安卓上整条输出路由逻辑旁路**（交给系统 AudioPolicy，不再自己钉设备）

**Windows 端完全不受影响**：`useNative` 为 false，走原来的 `QMediaPlayer`。

### 6.4 引入的连带修复

| 问题                                 | 根因                                                                                                                                                  |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- |
| 切换设备时**两路音频同时播**、关不掉 | `setOutputMode()` 里的 `applyRoute()` 漏了 `useNative` 守卫，把 Qt 的 MediaPlayer 也拉起来播了                                                        |
| **歌词界面一直闪**                   | ① `displayLyrics` 把占位数组写在三元表达式里，每次求值都新建数组对象 → ListView 重建；② `LyricsLoader.load()` 无防重复，`loaded` 在 true/false 间抖动 |
| 蓝牙断开后**外放**                   | 用户要求：检测到"蓝牙 → 非蓝牙"就 `pause()`。用公开 API `AudioPlaybackConfiguration.getAudioDeviceInfo()` 轮询设备类型                                |

---

## 七、附带成果

- **版本升到 0.1.2**（`versionCode` 3 → 4）
- **Qt 安装恢复干净**：两个二进制补丁全部回退，`.so` 与 `.orig` 的 SHA-256 一致、`jar` 的 class CRC 一致
- **安卓隐藏「输出设备」入口**：`AudioManager.setPreferredDeviceForStrategy()` 是 **@SystemApi**，公开 SDK 里没有（`javap` 零命中），普通应用调不动；而真正稳的 `AudioTrack.setPreferredDevice()` 需要输出层自己用 AudioTrack 实现，代价过高。故仅对 Windows 开放。

---

## 八、经验总结

### 8.1 方法论

1. **"系统数据正常"不等于没问题。** dumpsys 显示零欠载、电平连续，是因为蓝牙 HAL **重复上一帧**而不是写静音。听感卡但数据"干净"，这正是本次绕远路的根源。
2. **注释会被人当成事实来推理。** `switchTo()` 的注释写着"完全相同"，实际缺了最关键的一步 —— 这个矛盾最终是用户读代码时发现的。**写注释时描述"当前实现做了什么"，不要写"等价于什么"。**
3. **反复修改同一处功能，必然留下过期注释。** 本次共修正 7 处过期注释，其中 2 处与现行行为**完全相反**。
4. **控制变量比猜方向重要。** 方案一失败后才看清方案二该做什么；方案四两次补丁的失败顺序（先倍数后 capacity）也说明了"瓶颈要找对"。
5. **判断代码是否删净不能只搜二进制字符串。** dex 里存着整个 Android framework 的方法名字符串池（`setPreferredDevice` 与 `setPrimaryClip` 等系统 API 名混在一起），会造成误报。**以源码 grep 为准。**

### 8.2 架构层面

1. **框架的默认配置不一定是可调的。** Qt 把 AAudio 的缓冲写死在 `constexpr` 里，且没有暴露任何配置入口（连环境变量都没有）。**当框架在这点上没有给你接口时，改上层不如换一条路。**
2. **与系统组件同路是最稳的策略。** 我们花了一整天想把 Qt 这条路调通，而"换成系统原生播放"一次就解决了 —— 因为后者本来就是系统验证过的配置。

---

## 附录 A：关键数据速查

```bash
# 音频流类型与参数（判据：type 是 AAudio 还是 android.media.*）
adb shell dumpsys audio | grep AudioPlaybackConfiguration | grep <uid>

# 输出线程归属与 HAL 缓冲（判据：AudioOut_D vs AudioOut_15、frame count）
adb shell dumpsys media.audio_flinger | grep -A 20 "name AudioOut_D"

# 50ms 电平包络（查音频空洞）
adb shell dumpsys media.audio_flinger | grep -A 40 "name AudioOut_D"

# 欠载计数（查 underrun）
# 输出中 "Normal mixer raw underrun counters: partial=0 empty=0"

# 音轨增删时序（查是否重叠）
adb shell dumpsys media.audio_flinger | grep -E "AT::(add|remove)"

# 取应用 uid
adb shell "pm list packages -U | grep <包名>"
```

> git-bash 下调用 `adb shell` 涉及手机内路径时，需先  
> `export MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV=1`。

## 附录 B：本文涉及的源码位置（Qt 6.12.0）

| 位置                                                 | 内容                                                        |
| ---------------------------------------------------- | ----------------------------------------------------------- |
| `src/multimedia/android/qaaudiostream.cpp:15`        | `constexpr int bufferSizeInBursts = 3`                      |
| `src/multimedia/android/qaaudiostream.cpp:80`        | `AAudioStreamBuilder_setBufferCapacityInFrames`             |
| `src/multimedia/android/qaaudiostream.cpp:165`       | `setBufferSizeInFrames(burstSize * 3)`                      |
| `src/multimedia/android/qandroidaudiosink.cpp:34-36` | `bufferCapacity = ... : 1024`                               |
| `src/multimedia/qmediadevices.cpp:220`               | `defaultAudioOutput()` 找 `isDefault()`                     |
| `src/multimedia/android/qandroidaudiodevices.cpp:71` | `isDefault = (i == 0)`                                      |
| `src/multimedia/audio/qaudiooutput.cpp:215`          | `setDevice()` 的同值守卫（`if (d->device == dev) return;`） |

## 附录 C：相关文档

- `docs/android-bluetooth-audio.md` —— 同一问题的**排查过程笔记**（含更细的源码级查证与设备枚举缺陷分析）。  
  本文是它的**结论与复盘**，两者互补。
