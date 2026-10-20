import QtQuick
import QtMultimedia
import "../js/DeviceUtils.js" as DeviceUtils
import "../js/Format.js" as Format

// 播放引擎：真实音频播放，对外只暴露界面需要的状态
Item {
    id: engine
    width: 0
    height: 0

    // playing 两条链路语义不同：
    //   Windows —— 命令式，play()/pause() 乐观置位
    //   安卓    —— 状态式，唯一来源是 nativePlayer 的状态镜像（setPlayingState）
    // ⚠️ 安卓下任何地方都不要再写 engine.playing：镜像是边沿检测上报的，
    //    写入后镜像不变就再也不会发信号，界面会永远停在那个值上。
    property bool playing: false
    property string source: ""

    // ---------- 平台分派：安卓走系统原生播放器 ----------
    // Qt 安卓输出走 AAudio(PRIMARY, 21.3ms 缓冲)，A2DP 抖动下余量≈0 → 蓝牙卡顿；
    // 系统 MediaPlayer 走 DEEP_BUFFER(42.7ms)，与系统播放器同路。详见 2026-10-14 日记。
    readonly property bool useNative: Qt.platform.os === "android"
                                      && typeof nativePlayer !== "undefined"
                                      && nativePlayer.available()

    readonly property int positionMs: engine.useNative ? nativePlayer.position : player.position
    readonly property int durationMs: engine.useNative ? nativePlayer.duration : player.duration

    // 原生播放器 → 本引擎的信号桥接（仅在安卓上有 target）
    Connections {
        target: engine.useNative ? nativePlayer : null

        function onEnded() {
            engine.ended()
        }
        function onErrorOccurred(message) {
            engine.playbackError(engine.source, message)
        }
        function onPositionChanged() {
            engine.progressChanged(nativePlayer.position, nativePlayer.duration)
        }
        function onDurationChanged() {
            engine.progressChanged(nativePlayer.position, nativePlayer.duration)
        }
        function onPlayingChanged() {
            engine.playing = nativePlayer.playing
        }
        function onOutputDeviceLost() {
            // 蓝牙 / 耳机断开，音频落到扬声器：暂停而不是外放。
            // playing 不用在这里写 —— nativePlayer 侧是先 setPlayingState(false)
            // 再发这个信号的，上面的 onPlayingChanged 已经把界面同步好了。
            root.showToast("蓝牙已断开，已暂停播放")
        }
    }

    signal ended()
    signal progressChanged(int positionMs, int durationMs)
    // 播放失败（源被删除、格式不支持等）：交给上层提示，必要时清理曲目
    signal playbackError(string file, string message)

    // 重建音频链路后要恢复的播放进度；-1 表示无需恢复
    property int pendingSeekMs: -1


    // 正在重建音频链路。重建过程本身会再触发一次 audioOutputsChanged，
    // 若不挡住就会「重绑 → 设备变化 → 再重绑」自激成死循环，播放被反复打断
    // （Windows 音频后端在流启动时会刷新设备列表，必现）
    property bool rebinding: false

    // 上一次真正生效的输出设备 id：设备列表刷新但目标没变时不再重绑
    property string activeDeviceId: ""

    // 当前绑定的设备已失效（蓝牙断开 / 耳机拔出）但还没回落。
    // 断开时先暂停不动设备，等用户下次点播放再决定走哪条路
    property bool deviceStale: false

    // ---------- 输出设备档位 ----------
    // "auto" = 自动：蓝牙在线就切到蓝牙，否则跟随系统默认；非 "auto" 时为用户手动指定的设备 id
    property string outputMode: "auto"
    // 自动模式下，若用户选定的设备当前不可用，就临时回落；恢复后自动切回
    readonly property bool manualMode: outputMode !== "auto"

    // ---------- 平台差异 ----------
    // 选路只在 Windows 实际执行；分平台判据保留：
    //   · 安卓 isDefault 是「枚举列表第一个」，不跟随系统默认
    //   · 安卓蓝牙只允许钉 A2DP（SCO 是通话通道）
    readonly property bool isAndroid: Qt.platform.os === "android"


    // 在线的蓝牙 A2DP 设备 id，没有返回空串。必须是函数 —— 连接状态会变
    function androidA2dpId() {
        if (!engine.isAndroid) return ""
        if (typeof folderScanner === "undefined") return ""
        return "" + folderScanner.bluetoothA2dpDeviceId()
    }

    // 已确认在线的设备：当前平台是否允许把音频流钉到它
    // 安卓蓝牙只认 A2DP —— SCO 是通话通道，钉上去没声音
    function isPinnableDevice(device, a2dpId) {
        if (!device) return false
        if (!engine.isAndroid) return true
        if (!isBluetoothDevice(device)) return true
        return ("" + device.id) === a2dpId
    }

    // 按 id 判断能不能钉（完备：设备离线也返回 false，调用方无需再判空）
    function canPinDevice(deviceId) {
        if (!deviceId || deviceId === "auto") return false
        var d = findDeviceById(deviceId)
        if (!d) return false                          // 设备当前离线
        return engine.isPinnableDevice(d, engine.androidA2dpId())
    }

    // 外部（Main）设置输出档位：Auto 或具体设备 id
    function setOutputMode(deviceId) {
        // 安卓：播放已交给系统原生播放器，输出路由由 AudioPolicy 自己决定，
        // 手动选设备对它无效。若这里继续走 applyRoute，会把 Qt 的 MediaPlayer 也拉起来播
        // → 两路音频同时播放、时间不同步、且只能停掉一路（2026-10-14 实测的严重 bug）
        if (engine.useNative)
            return

        engine.outputMode = (deviceId === "" || deviceId === "auto") ? "auto" : ("" + deviceId)
        engine.deviceStale = false

        if (engine.manualMode) {
            // 两层守卫缺一不可：d 为空 = 设备当前离线；canPinDevice = 当前平台不允许钉。
            // 曾经只用 canPinDevice（当时不查存在性），applyRoute(null) 抛过 TypeError
            var d = findDeviceById(engine.outputMode)
            if (d && engine.canPinDevice(engine.outputMode)) {
                applyRoute(d)
                return
            }
            // 指定设备当前离线 / 不允许钉：保持档位，按 Auto 逻辑过渡
        }
        // 回到 Auto：立刻重新选路
        engine.refreshAudioRoute(true)
    }

    // 设备列表快照，供 UI 展示（纯数据，避免 QML 持有 QAudioDevice 引用）
    function availableOutputDevices() {
        var result = []
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            var desc = "" + outputs[i].description
            result.push({
                id: "" + outputs[i].id,
                description: desc,
                label: DeviceUtils.friendlyDeviceName(desc),
                isDefault: outputs[i].isDefault,
                isBt: DeviceUtils.isBluetoothDescription(desc)
            })
        }
        return result
    }

    // 按 id 找设备对象（找不到返回 null）
    function findDeviceById(deviceId) {
        if (!deviceId || deviceId === "auto") return null
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            if ("" + outputs[i].id === deviceId) return outputs[i]
        }
        return null
    }

    // 新增/移除设备时通知外部刷新列表
    signal outputDevicesChanged()

    // source 用命令式赋值（不用绑定）：重建链路时需要重设 source，
    // 绑定会被 imperative 赋值打断，之后切歌就失效
    onSourceChanged: {
        // 清掉上一次重建留下的待恢复进度，否则会在新歌加载完时跳位置
        engine.pendingSeekMs = -1
        if (engine.useNative)
            return;                         // 安卓：源由 nativePlayer.setSource 管理
        player.source = engine.source
    }

    // 切歌。Windows 上必须**连音频输出一起重建**，否则蓝牙上切几次后会持续卡顿：
    // 只 stop + 换 source 时底层 audio sink 仍沿用旧实例，坏状态没被清掉。
    // 这里用「解绑再重绑 audioOutput」强制平台层重建 sink，设备本身不变。
    function switchTo(url, autoplay) {
        engine.pendingSeekMs = -1

        if (engine.useNative) {
            // 安卓：交给原生播放器。playing 不在这里写 ——
            // nativePlayer.setSource() 会归零镜像并发信号（同步送达），界面随即同步
            engine.source = url
            nativePlayer.setSource(url, autoplay)
            return
        }

        engine.playing = false
        player.stop()
        player.source = ""              // 彻底销毁旧播放器及其音频流
        player.audioOutput = null
        player.audioOutput = audio
        engine.source = url
        if (autoplay) engine.play()
    }

    function play() {
        if (engine.useNative) {
            nativePlayer.play()
            return
        }
        // 上次拔耳机/断蓝牙时只暂停没回落，现在用户要播了：重新按优先级选路
        if (engine.deviceStale) engine.recoverRoute()
        engine.playing = true
        player.play()
    }

    // 启动即按优先级对齐一次输出设备（手动档位 → 蓝牙 → 系统默认）。
    // 不这么做，AudioOutput 会一直保持 Qt 构造时的绑定，要等设备列表变化才第一次选路。
    // 注意别在这里写 activeDeviceId，否则 applyRoute 的"目标没变就不重建"会误跳过首次选路
    Component.onCompleted: {
        if (engine.useNative)
            return;   // 安卓：路由交给系统，不钉任何设备
        var target = null
        if (engine.manualMode && engine.canPinDevice(engine.outputMode))
            target = findDeviceById(engine.outputMode)
        if (!target) target = bluetoothDevice()
        if (!target && !engine.isAndroid) target = mediaDevices.defaultAudioOutput
        if (target && ("" + target.id) !== "") {
            audio.device = target
            engine.activeDeviceId = "" + target.id
        }
    }

    function pause() {
        if (engine.useNative) {
            nativePlayer.pause()
            return
        }
        engine.playing = false
        player.pause()
    }

    function toggle() {
        if (engine.playing) engine.pause()
        else engine.play()
    }

    function stop() {
        if (engine.useNative) {
            nativePlayer.stop()
            return
        }
        engine.playing = false
        player.stop()
    }

    // 播完当前曲目后从头再来（用于单曲循环）
    function replay() {
        if (engine.useNative) {
            nativePlayer.seekTo(0)
            nativePlayer.play()
            return
        }
        engine.playing = true
        player.setPosition(0)
        player.play()
    }

    function seekToMs(ms) {
        if (engine.useNative) {
            nativePlayer.seekTo(Math.max(0, ms))
            return
        }
        if (!player.seekable) return
        var total = player.duration
        var target = Math.max(0, ms)
        if (total > 0) target = Math.min(target, total - 200)
        player.setPosition(target)
    }

    // 播放器时间显示（未知时长显示 0:00；列表里那套显示 --:--）
    function formatMs(ms) {
        return Format.formatMs(ms, "0:00")
    }

    // ---------- 输出设备路由（仅 Windows；安卓由 useNative 全程旁路） ----------
    // 音频流在创建时就绑定了输出设备，播放中插拔耳机不会自动迁移，所以要显式选路。
    // 优先级：手动档位 → 蓝牙优先（有线+蓝牙同时在线时用户期望走蓝牙）→ 系统默认
    MediaDevices {
        id: mediaDevices
    }

    Connections {
        target: mediaDevices
        function onAudioOutputsChanged() {
            engine.outputDevicesChanged()      // 让 UI 刷新候选列表
            if (engine.useNative)
                return;                        // 安卓：路由交给系统
            if (engine.rebinding) return       // 重建链路会再触发一次，必须忽略，否则自激
            // Windows 后端在流启动瞬间会连续上报多次，防抖合并成一次
            routeDebounce.restart()
        }
    }

    Connections {
        target: mediaDevices
        function onDefaultAudioOutputChanged() {
            if (engine.rebinding) return
            routeDebounce.restart()
        }
    }

    Timer {
        id: routeDebounce
        interval: 120
        repeat: false
        onTriggered: engine.refreshAudioRoute()
    }

    // 设备是否仍在系统列表里
    function isDeviceAlive(deviceId) {
        if (deviceId === "") return false
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            if ("" + outputs[i].id === deviceId) return true
        }
        return false
    }

    function currentDeviceAlive() {
        return isDeviceAlive("" + audio.device.id)
    }

    // 按描述 / id 关键字识别蓝牙输出
    function isBluetoothDevice(device) {
        var text = ("" + device.description + " " + device.id).toLowerCase()
        return text.indexOf("bluetooth") >= 0 || text.indexOf("a2dp") >= 0
    }

    // 找到在线蓝牙设备，没有返回 null。
    // Windows 取第一个描述含 bluetooth/a2dp 的；安卓 A2DP/SCO 描述都是 "Bluetooth"，
    // 只能问 C++ 要 A2DP 的 id（选路已旁路，此分支保留备查）
    function bluetoothDevice() {
        if (engine.isAndroid) {
            var id = engine.androidA2dpId()
            if (id === "") return null
            return findDeviceById(id)
        }
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            if (isBluetoothDevice(outputs[i])) return outputs[i]
        }
        return null
    }

    // 解析应该用哪个输出设备；返回 null 表示「无需变更」。
    // allowFallback：false（被动刷新）当前设备消失时只暂停不回落，避免拔耳机瞬间声音
    //                悄悄跳到扬声器；true（用户点播放）才允许回落到默认设备，否则会"没声音"
    function resolveTargetDevice(allowFallback) {
        var curId = "" + audio.device.id

        // ⓪ 手动档位优先；canPinDevice 同时挡住「离线」和「平台不允许钉」
        if (engine.manualMode) {
            var wanted = findDeviceById(engine.outputMode)
            if (wanted && engine.canPinDevice(engine.outputMode)) {
                if ("" + wanted.id === curId) return null      // 已经在用
                return wanted
            }
            // 指定设备不在线：不强行切，走 Auto 逻辑过渡，等它回来
        }

        // ① 蓝牙在线且当前没用它 → 抢过去
        var bt = bluetoothDevice()
        if (bt && "" + bt.id !== curId) {
            return bt
        }

        // ② 已经在用蓝牙：不动
        if (bt && "" + bt.id === curId) return null

        // ③ 当前设备已消失（蓝牙断开 / 耳机拔出）
        if (curId !== "" && !currentDeviceAlive()) {
            if (!allowFallback) return null
        }

        // ④ 跟随系统默认。安卓返回 null：它的 defaultAudioOutput 是「列表第 0 个」，
        //    会随设备刷新而变，拿它判断必然误判成"默认设备变了"→ 反复重建链路
        if (engine.isAndroid) return null
        var def = mediaDevices.defaultAudioOutput
        if (("" + def.id) === "") return null
        if (curId === "" || curId !== "" + def.id) return def
        return null
    }

    // force：忽略快速返回，强制重新选路（用户主动改档位时用）
    function refreshAudioRoute(force) {
        if (engine.useNative)
            return;         // 安卓：路由交给系统，整条选路链路都不参与
        if (engine.rebinding) return

        var curId = "" + audio.device.id
        var curAlive = currentDeviceAlive()
        var bt = bluetoothDevice()
        var btId = bt ? "" + bt.id : ""
        var defId = "" + mediaDevices.defaultAudioOutput.id

        if (!force) {
            // 快速返回：当前设备在线且没有任何「要重新选路」的信号。
            // 三个信号必须往下走：手动档位改了 / 蓝牙在线但没用它 / 当前不是系统默认
            if (curId !== "" && curAlive && !engine.deviceStale) {
                var manualWants = engine.manualMode
                        && engine.outputMode !== curId
                        && findDeviceById(engine.outputMode) !== null
                var btWantsToTake = !engine.manualMode && bt && btId !== curId
                var defChanged = !engine.isAndroid && defId !== "" && curId !== defId
                if (!manualWants && !btWantsToTake && !defChanged) {
                    return
                }
            }
        }

        var target = resolveTargetDevice(false)
        if (target) {
            applyRoute(target)
            return
        }

        // 没有可切的目标且当前设备已消失：只暂停、不自动回落，等下次点播放再选路
        if (!curAlive) {
            if (engine.playing) {
                engine.playing = false
                player.pause()
            }
            engine.deviceStale = true
        }
    }

    // 用户点播放时调用：允许回落，否则拔掉耳机后点播放会停在已拔掉的设备上（没声音）
    function recoverRoute() {
        var target = resolveTargetDevice(true)
        if (!target) {
            engine.deviceStale = false
            return
        }
        engine.deviceStale = false
        applyRoute(target)
    }

    function applyRoute(target) {
        // 双保险：安卓上不该走到这里，一旦漏网会把 Qt 的 MediaPlayer 也拉起来播（两路音频）
        if (engine.useNative)
            return

        var targetId = "" + target.id
        if (targetId === engine.activeDeviceId) {
            return
        }

        engine.rebinding = true
        audio.device = target
        engine.activeDeviceId = targetId
        rebindAudio()
        engine.rebinding = false
    }

    // 重建链路：停流 → 重设 source → 续播，让新流绑到切换后的设备
    function rebindAudio() {
        if (player.source === "") return
        var wasPlaying = engine.playing
        var pos = player.position
        player.stop()
        player.source = ""
        player.source = engine.source
        if (wasPlaying) player.play()
        pendingSeekMs = pos
    }

    AudioOutput {
        id: audio
    }

    MediaPlayer {
        id: player
        audioOutput: audio

        onPositionChanged: engine.progressChanged(player.position, player.duration)
        onDurationChanged: engine.progressChanged(player.position, player.duration)

        onMediaStatusChanged: function(status) {
            if (status === MediaPlayer.EndOfMedia) {
                engine.ended()
                return
            }
            // 源文件被删掉 / 后端无法识别时停在这一状态：
            // 界面会显示"在播放"但一点声音都没有，必须上报出去
            if (status === MediaPlayer.InvalidMedia) {
                engine.playing = false
                engine.playbackError(engine.source, "媒体无效或已被删除")
                return
            }
            // 链路重建后恢复到原来的播放进度
            if ((status === MediaPlayer.LoadedMedia || status === MediaPlayer.BufferedMedia)
                    && engine.pendingSeekMs >= 0) {
                var target = engine.pendingSeekMs
                engine.pendingSeekMs = -1
                if (target > 0 && player.seekable) player.setPosition(target)
            }
        }

        onErrorOccurred: function(error, errorString) {
            if (error === MediaPlayer.NoError) return
            engine.playing = false
            engine.playbackError(engine.source, "" + errorString)
        }
    }
}
