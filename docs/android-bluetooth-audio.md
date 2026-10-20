# Qt Android 蓝牙音频问题：排查与修复记录

- **日期**：2026-10-14
- **测试设备**：**OPPO PLJ110**、**Android 16**（`ro.build.version.release=16`，`sdk=36`）、
  安全补丁 `2026-08-01`、构建号 `PLJ110_16.0.10.502(CN01)`
- **应用版本**：0.1.1
- **状态**：两个问题均已修复，并经真机验证

> ⚠️ **本文是当天的排查快照，其中问题 1 的修法后来被推翻。** 修补 Qt jar 的方案已在
> 2026-10-14 整体回退，最终解决方式是把安卓播放换成系统原生 `MediaPlayer`
> （见 `bluetooth-audio-stutter-solution.md`）。§三、§四 中与补丁相关的部分已标注失效。

> **关于证据的来源标注**
>
> 正文中每条关键论断都标注了来源，请按需采信：
>
> | 标记       | 含义                                                                        |
> | ---------- | --------------------------------------------------------------------------- |
> | `【实测】` | 在本机或真机上用命令**直接观察到**的输出（`dumpsys`、logcat、`getprop` 等） |
> | `【源码】` | Qt 或 Android **源码原文**，已逐条打开文件核对（附行号）                    |
> | `【推断】` | 我的推理，**没有直接观测支撑** —— 属于"最合理的解释"，不是已证事实          |
>
> 文末《附录 A》列出了全部【推断】条目，便于日后逐一验证或推翻。

## 摘要

安卓端出现过两个**互相独立**的问题，第二个是在修好第一个之后才暴露出来的（因为此前根本听不到声音）：

| #   | 问题                                                       | 根因                                                                 | 修法                                          |
| --- | ---------------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------- |
| 1   | 连上蓝牙耳机后**完全没有声音**                             | Qt 的 Android 音频设备枚举缺陷：**SCO 顶替 A2DP** 成为"默认输出设备" | 修补 Qt 的 jar，把 SCO 从**输出**设备列表剔除（**后已回退**） |
| 2   | 有声音后，**切歌之后一直卡顿**（切一次输出设备可暂时恢复） | 切歌时**新旧音频流在 A2DP 输出上短暂共存**（重叠 150~300ms）         | 切歌改走"**先彻底销毁旧流、再建新流**"的链路  |

一句话总结两者的性质：

- 问题 1 是 **Qt 的缺陷**，我们只能通过修补 Qt 安装来绕开；
- 问题 2 是 **我们自己切歌时序的问题**，改两处 QML 即可解决。

> 修完这两个之后，又发现并修掉了**第三个**：安卓上「跟随系统默认」被我早期误关，
> 导致插有线耳机不切换、设备消失后无法回落、蓝牙断开后点播放没声音。
> 根因是我当时的判断漏掉了 Qt 的排序步骤。详见 **§6.3**。

---

## 一、问题 1：蓝牙完全没有声音

### 1.1 现象

- 连上蓝牙耳机后，自动档不响；**手动选择蓝牙设备也不响**
- 界面播放进度正常推进、还会自动切下一首 —— 说明**解码是好的，声音出不去**
- 扬声器、有线耳机一切正常
- 系统自带播放器、其他音乐 App 在同一副耳机上一切正常

### 1.2 先排除的错误方向

排查初期走过三个弯路，记录在此以免重蹈：

| 方向                     | 排除依据                                                        |
| ------------------------ | --------------------------------------------------------------- |
| 音频文件本身有问题       | 其他播放器播放同一文件完全正常                                  |
| 音频被拽回通话通道       | 实测 `Actual mode = MODE_NORMAL`，设备列表中 SCO 未处于激活状态 |
| 我们的选路逻辑抢错了设备 | 显式钉设备同样无效；日志显示选路只执行一次、无抖动              |

### 1.3 根因

给 C++ 加了一条能进 logcat 的诊断通道（安卓 Release 下 QML 的 `console.log` 进不了 logcat），把 **Qt 看到的设备清单**与**系统真实设备**打出来对比：

```
系统真实输出设备： 12743(SCO)   2(听筒)   3(扬声器)   12750(A2DP)
Qt 交给 QML 的：  [12743]Bluetooth*   [3]Built in speaker   [2]Built in earpiece
                          ↑ 只有 SCO，A2DP 根本不在 Qt 的列表里
```

【实测】我们的音频流被钉在了一个**不能正常发声的设备**上：

```
dumpsys audio                → deviceIds:[12672] type:AAudio
dumpsys media.audio_flinger  → AudioOut_D (PRIMARY) → 0x20 BLUETOOTH_SCO_HEADSET
                               （正常播放器在 0x80 BLUETOOTH_A2DP）
```

> ⚠️ 这里的 `12672` 与上面设备清单里的 `12743(SCO)` **不是同一个 id** ——
> 两处证据取自**不同时刻**（设备 id 会随每次蓝牙连接变化）。
> 当时能确认的事实只有一条：**音频流所在的那个 id，不在系统"已连接输出设备"列表里**。

四段 Qt 源码串起来，构成完整因果链：

1. **蓝牙去重只保留第一个** —— `QtAudioDeviceManager.getAudioDevices()`：

   ```java
   } else if (isBluetoothDevice(deviceInfo)) {
       if (bluetoothDeviceAdded) continue;   // 第二个蓝牙设备被丢弃
       bluetoothDeviceAdded = true;
   }
   ```

2. **A2DP 与 SCO 排序优先级相同** —— `sortAudioDevices()` 的 `priorityMap` 里两者都是 `2`，`Arrays.sort` 是稳定排序，所以最终顺序等于 `AudioManager.getDevices()` 的系统枚举顺序。本机系统**先返回 SCO**。

3. **`isDefault` 不是系统默认** ——【源码】`qandroidaudiodevices.cpp:69-71`，创建设备时把
   **`i == 0`** 作为 `isDefaultDevice` 参数传入，也就是"枚举列表的第一个"：

   ```cpp
   devices << QAudioDevicePrivate::createQAudioDevice(std::make_unique<QAndroidAudioDevice>(
           QString::number(id).toUtf8(), description, mode,
           preferredFormatForDevice(deviceInfo), isBluetoothDevice, i == 0));
   //                                                                  ^^^^^^ ← isDefault
   ```

   ⚠️ 这个文件里**搜不到 `isDefault` 这个词**（源码写的是 `i == 0`），
   查证时若只 grep `isDefault` 会误判成"不存在"。

4. **`QAudioOutput` 一构造就钉设备** —— `qaudiooutput.cpp:62`：

   ```cpp
   QAudioOutput::QAudioOutput(QObject *parent)
       : QAudioOutput(QMediaDevices::defaultAudioOutput(), parent)   // ← 构造即钉
   ```

   而 `setDevice(QAudioDevice())` 传空设备**也会回退**到同一个默认值（同文件 `:208`）——
   **公共 API 无法表达"未指定设备"**。

**结果** —— 分实测与推断两部分说明：

- 【实测】Qt 交给 QML 的设备清单里，**唯一的蓝牙项就是 SCO**（`[12743]Bluetooth*`，
  带 `*` 号 = 被认为是默认设备），而真正的 A2DP（`12750`）**完全不在清单里**。
  也就是说：**我们想钉 A2DP 也钉不到**。
- 【实测】此状态下播放**没有任何声音**，而扬声器、有线耳机一切正常。
- 【推断】"SCO 是蓝牙通话通道（HFP），不用于媒体播放，所以听不到声音"——
  **这是对现象的解释**。我没有抓到 AAudio 的拒绝日志，也没有抓到音频路由层的报错，
  因此**失败的确切环节未经观测**。可以确定的是：**输出落在 SCO 时没有声音，换到 A2DP 后正常**。

> 关键认知：**钉设备发生在 `AudioOutput` 构造时**，与我们是否调用 `setDevice` 无关。
> 所以"我们的代码不主动钉设备"这种修法**从根本上无效**。

### 1.4 修复

新增 `tools/patch_qt_android_multimedia.sh`，**替换 Qt 安装目录 jar 里的 class**，把 SCO 从**输出**设备列表中剔除（**输入设备保留**，蓝牙麦克风仍可用于录音）。**该脚本已随补丁回退而删除。**

之后 A2DP 成为唯一的蓝牙输出设备，并因优先级排在列表首位而成为默认设备，行为与系统播放器一致。

配套的 QML 侧改动（避免反向破坏路由）：

- 新增 `folderScanner.bluetoothA2dpDeviceId()`（JNI），直接向 `AudioManager` 查询 `TYPE_BLUETOOTH_A2DP` 的设备 id（原生播放接入后已无调用路径）；
- 抽出 `isPinnableDevice()` 作为**唯一判据**，UI 置灰判据与执行判据共用同一个函数 —— 杜绝"界面上显示置灰、实际却能切换"这类不一致（UI 置灰那一半已在原生播放接入后移除，该函数现只剩平台策略）。

### 1.5 验证

```
修复后 Qt 设备清单：outputs(3): [13613]Bluetooth*  [3]Built in speaker  [2]Built in earpiece
                              a2dp=13613
我们的音频流：       deviceIds:[13613]  channelMask=0x3(立体声)  sampleRate=48000
输出线程：           AudioOut_D (PRIMARY) → 0x80 AUDIO_DEVICE_OUT_BLUETOOTH_A2DP
```

设备从 SCO 变回 A2DP，声道从单声道变成立体声。真机确认有声音。

---

## 二、问题 2：切歌后持续卡顿

### 2.1 现象（关键签名）

真机用户给出了一条**极有价值的复现签名**：

> **切到「扬声器」→ 再切回「自动」→ 立刻恢复；然后一切歌，又开始卡，并且一直卡。**

配套的其它特征：

- **第一次播放完全正常**
- **扬声器上从不卡，只有蓝牙耳机卡**
- 不是"切歌瞬间断一下"，而是**切完之后持续卡**

### 2.2 已排除的方向

以下假设**全部被实测证伪**，不必重查：

| #   | 假设                                           | 证伪依据                                                                                                                                                           |
| --- | ---------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1   | 音频文件有问题（如 ID3 标签过大）              | 其他播放器播放同一文件正常。**这是早期的一次误判，已收回**                                                                                                         |
| 2   | 流被反复重建 / 选路自激                        | `piid` 稳定不变；应用日志全程无 `applyRoute` / `REBIND`                                                                                                            |
| 3   | 欠载 / 数据供给不上                            | A2DP 线程 `Normal mixer raw underrun: partial=0 empty=0`                                                                                                           |
| 4   | 音频数据不连续                                 | **HAL 电平包络**（50 ms 分辨率，连测 29 秒）**无一格静音**，-10~-38 dB 连续                                                                                        |
| 5   | 切歌重建链路耗时长                             | 【实测】扬声器上播放和切歌**从不卡**；而两者走的是同一份代码路径                                                                                                   |
| 6   | 换用 Android 原生后端                          | 【实测】切换后 `Actual mode` 变为 `MODE_IN_COMMUNICATION`，音频流落到**扬声器**（`deviceIds:[2]`）而非蓝牙，A2DP 电平包络停止更新 → 蓝牙没声音。**已做实验并回退** |
| 7   | 我们专属的 audio patch 重建                    | 汽水音乐同样产生 `0x80→0x80` patch，频率还更高（8 分钟 4 次）。**用对照实验证伪**                                                                                  |
| 8   | 持续坏状态（通话模式 / 降到 SCO / 旧音轨泄漏） | 卡顿中实测均为否：`MODE_NORMAL`、无 `bt_sco`、**只有 1 条 track**、`empty=0`                                                                                       |
| 9   | PRIMARY 与 DEEP_BUFFER 线程差异                | 这是**差异**不是**因果** —— 我们音轨里常驻 212~340 ms 已排队音频，"缓冲不足"说不通。**当时把它当根因属过度推断，已修正**                                           |

### 2.3 根因

在 `dumpsys media.audio_flinger` 的本地事件日志里，抓到了切歌时的时序：

```
17:22:02.766  AT::add    (新流, 48000)
17:22:02.933  AT::remove (旧流, 44100)      ← 旧流 167 ms 之后才被拆除
```

**新旧两条音频流在 A2DP 输出上短暂共存（150~300 ms），两条都进混音器。**

这个解释与**所有**观察到的现象吻合：

| 现象                   | 解释                                                                              |
| ---------------------- | --------------------------------------------------------------------------------- |
| 只有蓝牙卡             | 给 A2DP 输出叠加/撤下音轨会打断蓝牙链路；扬声器路径对此不敏感                     |
| 第一次播放不卡         | 前面没有旧流，不存在重叠                                                          |
| "切一次输出设备"能恢复 | 那条路径是 `applyRoute → rebindAudio`，它**先彻底销毁旧流**再建新流，时序是干净的 |
| "一切歌又卡"           | 切歌走的是另一条路径（`stop()` → 改 `source`），Qt 在拆旧流的同时建新流           |

### 2.4 修复

**让切歌走与"恢复"完全相同的链路。**

`components/PlaybackEngine.qml` 新增 `switchTo()`：

```qml
function switchTo(url, autoplay) {
    engine.pendingSeekMs = -1
    engine.playing = false
    player.stop()
    player.source = ""              // ← 关键：彻底销毁旧播放器及其音频流（先拆后建）
    engine.source = url             // onSourceChanged 里再去设 player.source
    if (autoplay) engine.play()
}
```

`Main.qml` 的 `selectSong()` 用 `engine.switchTo(song.file, autoplay)` 替换原来的
`engine.stop(); engine.source = …; if (autoplay) engine.play()`。

**安全性核过 Qt 源码**：`QFFmpegMediaPlayer::stop()` 只把 `mediaStatus` 置为 `LoadedMedia`
（**不是 `EndOfMedia`**，见 `qffmpegmediaplayer.cpp`），因此"换源前先停"**不会**误触发
`handleSongEnd()` 去跳下一首。

### 2.5 验证

```
改之前:  AT::add(新)   →  150~300ms 后  AT::remove(旧)          ← 两条流共存（重叠）
改之后:  AT::remove(旧) 18:32:15.551  →  AT::add(新) 18:32:15.694  ← 先拆后建，无重叠
```

应用日志中新增一条 `STATUS=0`（NoMedia），证明旧播放器**连同其音频流被真正销毁**之后才建新流 ——
这正是"切一次输出设备就能恢复"时走的同一条路径。

**最终由用户在真机确认：切歌不再卡顿。**

---

## 三、改动清单

| 文件                                      | 改动                                                                                 |
| ----------------------------------------- | ------------------------------------------------------------------------------------ |
| `tools/patch_qt_android_multimedia.sh`    | **新增** —— 修补 Qt 的 jar，剔除 SCO 输出设备（**后已回退，脚本已从仓库删除**）      |
| `folderScanner.h` / `folderScanner.cpp`   | 新增 `bluetoothA2dpDeviceId()`（JNI，包在 `#ifdef Q_OS_ANDROID` 内，非安卓返回空串）<br>**后因原生播放接入而失去调用路径** |
| `components/PlaybackEngine.qml`           | 新增 `switchTo()`；`isPinnableDevice()` 统一判据；安卓 A2DP 钉设备逻辑               |
| `Main.qml`                                | `selectSong()` 改用 `engine.switchTo()`                                              |
| `Qt6AndroidMultimedia.jar`（Qt 安装目录） | 被脚本**原地修补**，原文件备份为 `Qt6AndroidMultimedia.jar.orig`（**后已还原**）     |

**Windows 端未受影响**：`bluetoothA2dpDeviceId()` 在非安卓平台直接返回空串，
新增的守卫均以 `isAndroid` 为前提；35~40 组路由行为场景在改动前后行为一致。

---

## 四、维护须知

> **本节描述的做法已失效，仅作历史记录。** 该补丁已在 2026-10-14 回退，补丁脚本也已从
> 仓库删除 —— 蓝牙问题最终改用系统原生播放器解决（见 `bluetooth-audio-stutter-solution.md`）。
> 升级或重装 Qt 之后**不需要**再做任何修补。

原做法（已废弃）：执行 `bash tools/patch_qt_android_multimedia.sh`，脚本会把
`Qt6AndroidMultimedia.jar` 原地修补、原文件备份为 `.orig`；回退则 `cp <jar>.orig <jar>`。
脚本内置自检要求编译出的 class 是 **major 52**（Java 8 目标），且不含 `makeConcatWithConstants`。

### 版本号

本文写作时为 `0.1.1` / `ANDROID_VERSION_CODE 3`；当前为 `0.1.2` / `ANDROID_VERSION_CODE 4`，
桌面图标名 `Music Player`。

---

## 五、工程踩坑

### 补丁相关

1. **不能用工程的 `android/src/` 覆盖那个类**
   → 源码与 `libs/Qt6AndroidMultimedia.jar` 中的 class 会**同时进 dex**，报
   `QtAudioDeviceManager$$ExternalSyntheticLambda0 is defined multiple times`。
   必须**替换 jar 内的 class**。
2. **`javac` 必须加 `--release 8`**
   → JDK 9+ 的默认目标会产生 `invokedynamic` + `StringConcatFactory`（class major 67），
   D8 不做去糖 → 设备上类加载失败、**应用卡在启动闪屏**。`--release 8` → `StringBuilder` / major 52。
3. **Windows 上 `javac` / `jar` / `python` 都是 Windows 程序**
   → 路径必须写成 `D:/...`（可用 `cygpath -m`），`-cp` 的分隔符是 **`;`** 不是 `:`。

### 构建相关

4. **`ninja` 不会因为新增的 `android/src/` 文件而重跑 `androiddeployqt`**
   → 需 `touch android/AndroidManifest.xml` 触发重跑，新文件才会被拷进 gradle 工程。
5. **`cmake --build` 偶发失败**
   → 症状为 `Error compiling qml file:` 且**无细节**，常报在**未被改动**的文件上，
   重试 2~4 次即通过。与改动无关，不要当成自己引入的 bug。

### 调试通道

6. **本机 Qt 应用的 `console.log` / `qDebug` 默认不出现在 stdout**
   → 必须设置 `QT_ASSUME_STDERR_HAS_CONSOLE=1`。
7. **安卓 Release 构建下，QML 的 `console.log` / `console.warn` 进不了 logcat**
   → 要用 C++ 的 `__android_log_print(ANDROID_LOG_WARN, "mp-diag", ...)`，配合
   `adb logcat -d -s mp-diag:V` 读取。
8. **安全锁屏会让应用窗口 `visible:false`、QML 不渲染**
   → 看起来像"卡死在启动闪屏"。排查前先看
   `adb shell dumpsys window | grep mDreamingLockscreen`。**本次因此误判过一次。**

### 诊断手法（可复用）

9. **重建"实际写进 HAL 的音频电平包络"** —— 判断"到底有没有声音/有没有掉音"最硬的手段：

   ```bash
   adb shell dumpsys media.audio_flinger
   ```

   每个输出线程都带一段 `Signal power history`（**1 秒 / 50 毫秒两种分辨率**）。
   多次采样拼起来即可得到连续包络，**低于 -90 dB 即数字静音**。
   ⚠️ 该段**不按时间排序**，需要自行按时间戳排序去重。

---

## 附：诊断命令速查

```bash
# 1) 全局音频模式 & 已连接输出设备
adb shell dumpsys audio | grep -E "Requested mode|Actual mode"
adb shell dumpsys audio | grep -E "^ *Devices:" | sort -u

# 2) 查本应用 uid，再定位它的音频流落在哪个设备
adb shell pm list packages --uid <uid>
adb shell dumpsys audio | grep AudioPlaybackConfiguration | grep <uid>

# 3) A2DP 输出线程 / 欠载 / 电平包络
adb shell dumpsys media.audio_flinger | grep -A 20 "name AudioOut_D"

# 4) 音轨增删时序（看切歌是否发生新旧流重叠）
adb shell dumpsys media.audio_flinger | grep -E "AT::(add|remove)|CFG_EVENT"

# 5) 内部诊断日志（排查期由 debugLog() 输出；该代码已移除，此命令仅备查）
adb logcat -d -s mp-diag:V
```

> 提示：git-bash 下调用 `adb shell` 涉及手机内路径时，需先
> `export MSYS2_ARG_CONV_EXCL='*'; export MSYS_NO_PATHCONV=1`，否则路径会被 MSYS 转换破坏。

---

## 六、后续修复与代码清理（2026-10-14 当天完成）

### 6.1 诊断代码与死代码已全部清理

排查期留下的临时物已删除，净 **−68 行**：

- **临时诊断日志**：`PlaybackEngine.dlog()` / `rebuildCount` + 22 处调用；
  `folderScanner.debugLog()` + `#include <android/log.h>`；`Main.qml` 3 处调用
- **死代码（全项目零引用）**：`PlaylistStore.probing`、`folderScanner.hasAudioExtension()`、
  `PlaybackEngine.currentOutputDeviceId()`、`Main.root.outputDeviceId`、
  `appSettings.outputDeviceId`（**只写不读的持久化键**）

### 6.2 注释全部校准 —— 这才是反复修改的最大遗留

蓝牙逻辑反复修改后，**逻辑本身没有冗余**，但留下了 **7 处过期注释**，
其中两处与现行行为**完全相反**（例如「安卓上蓝牙和系统默认都不钉」——那是更早期方案的说法）。
已全部改正，另有 3 处不准确的 `SCO 是 8kHz 通话通道` 改为 `蓝牙通话通道（HFP）`。

> **教训：每次改变行为后必须回头改注释 —— 过期注释比没有注释更危险。**

### 6.3 安卓「跟随系统默认」—— 一次反转，随后回滚（保留作为教训）

> ⚠️ **本节描述的改动最终被回滚了**（同日晚些时候真机复现切歌卡顿，最终结论见 **§6.4**）。
> 保留本节是为了记录这次判断失误的完整过程。

**问题**：安卓上 ④「跟随系统默认」被整条跳过，导致**所有非蓝牙的设备变化都不响应** ——
插上有线耳机不切换、设备消失后无法回落、蓝牙断开后点播放没声音。

**关键认知修正**（我此前的判断有误）：跳过它的理由是「`isDefault` 是枚举列表第一个、不可信」，
这个判断**漏掉了排序步骤**。实际链路是：

- `QMediaDevices::defaultAudioOutput()` 找的是 `isDefault()`（`qmediadevices.cpp:220`）
- 安卓侧 `isDefault = (i == 0)`，而该列表已由 `sortAudioDevices()` 按优先级**稳定排序**
  （有线 1 → 蓝牙 2 → 扬声器 3 → 其他 4）
- → 它给出的是「**优先级最高的可用设备**」，确定且合理，不是随机值

**修法（两处，缺一不可）**：

| 位置 | 改动 |
|---|---|
| `resolveTargetDevice()` ④ | 删掉 `if (engine.isAndroid) return null` |
| `refreshAudioRoute()` 快速返回 | `defChanged` 去掉 `!engine.isAndroid`<br>（否则设备变化会被快速返回挡住，根本走不到 ④） |

**为什么安全**：到达 ④ 时**蓝牙必然不在线** —— ① ② 已穷尽"蓝牙在线"的全部情况
（`bt.id !== curId` → ① 返回；`bt.id === curId` → ② 返回）。因此该改动
**不可能影响蓝牙在线时的任何行为**，与切歌卡顿修复（`switchTo()`）也**零交集**。

**行为变化**：安卓向 Windows 看齐（两平台共用同一套决策，少一个平台分支）。
验证脚本 2 组期望值随之更新：㉕（插有线耳机 → 跟随）、㉗（蓝牙断开后点播放 → 回落到扬声器）。

**仍是原设计的一点**：③ 的 `if (!allowFallback) return null` 保留 ——
设备消失瞬间**不主动跳**到扬声器，只暂停并标记失效；只有用户主动点播放才回落。

### 6.4 ⭐ 切歌必须重建 audio sink（用户从注释里发现的关键差异）

**用户发现的矛盾**：`switchTo()` 的注释写着「走与输出设备重建**完全相同**的链路」，
但逐行对比后**并不相同**：

| 步骤 | `applyRoute → rebindAudio`（恢复路径） | `switchTo`（切歌路径） |
|---|---|---|
| **重设输出设备** | `audio.device = target` ✅ | **没有** ❌ |
| 更新 `activeDeviceId` | ✅ | 没有 |
| stop / 清 source / 设 source / play | ✅ | ✅ |

**缺的这一步才是关键**：`QAudioOutput::setDevice()`（`qaudiooutput.cpp:215` 起）
遇到**同值会被守卫挡掉**，只有真正"变化"过才会走 `d->setAudioDevice(dev)` ——
而那一步才会让平台层销毁并重建 **audio sink**。

**后果**：音轨（track）确实被重建了（`AT::remove` 先于 `AT::add`、无重叠），
但底层 **audio sink 沿用旧实例**，坏状态没被清掉 → 卡顿在若干次切歌后复现。
这与用户一开始给出的签名「切一次输出设备能恢复」完全吻合 —— 那条路径是真的重建了 sink。

**修法**（设备不变，因此不会外放）：

```qml
player.audioOutput = null       // 解绑 → 平台层销毁 sink
player.audioOutput = audio      // 重绑 → 按同一设备新建 sink
```

**前置验证**（先用 `qml.exe` 探针确认该操作合法，避免盲改）：

```
① 初始 = QAudioOutput(0x...880)
② 设为 null 后 = null
③ 重绑后 = QAudioOutput(0x...880)
```

**同时回滚的（§6.3 的改动）**：真机抓到「6 分钟内 15 个音轨被反复创建」，
原因是安卓的 `defaultAudioOutput` 是"设备列表第 0 个"、**会随设备列表刷新而变化**，
被用于 `defChanged` 判断时会误触发 `applyRoute` → 反复重建。
而切歌恰好会触发设备列表刷新，所以症状是"切歌后一直卡"。

> **两条方法论教训**：
> 1. 一个值"理论上可用"不等于"适合参与实时判断" —— 还要看它**变化的频率与时机**。
> 2. 注释会被当成事实来推理。`switchTo` 的注释把不完整的实现描述成"完全相同"，
>    直接掩盖了缺陷 —— 这条注释最终是**由用户读出来**才发现问题的。
>    写注释时，描述"当前实现做了什么"，不要写"等价于什么"。
