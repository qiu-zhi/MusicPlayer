import QtQuick
import QtMultimedia

// 播放引擎：真实音频播放，对外只暴露界面需要的状态
Item {
    id: engine
    width: 0
    height: 0

    property bool playing: false
    property string source: ""

    readonly property int positionMs: player.position
    readonly property int durationMs: player.duration

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
    // "auto" = 蓝牙优先（默认逻辑）；否则为用户手动指定的设备 id
    property string outputMode: "auto"
    // 自动模式下，若用户选定的设备当前不可用，就临时回落；恢复后自动切回
    readonly property bool manualMode: outputMode !== "auto"

    // 外部（Main）设置输出档位：Auto 或具体设备 id
    function setOutputMode(deviceId) {
        engine.outputMode = (deviceId === "" || deviceId === "auto") ? "auto" : ("" + deviceId)
        engine.deviceStale = false

        if (engine.manualMode) {
            var d = findDeviceById(engine.outputMode)
            if (d) {
                applyRoute(d)
                return
            }
            // 手动指定的设备当前不在线：保持档位，按 Auto 逻辑过渡
        }
        // 回到 Auto：立刻重新选路
        engine.refreshAudioRoute(true)
    }

    // 设备列表快照：供 UI 展示（纯数据，避免 QML 持有 QAudioDevice 引用）
    // 同时给出可读性更好的 label：系统原名对用户太生涩
    //   例：VX2478-2 (HD Audio Driver for Display Audio) → 显示器 (VX2478-2)
    function availableOutputDevices() {
        var result = []
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            var desc = "" + outputs[i].description
            result.push({
                id: "" + outputs[i].id,
                description: desc,
                label: engine.friendlyDeviceName(desc),
                isDefault: outputs[i].isDefault,
                isBt: isBluetoothDescription(desc)
            })
        }
        return result
    }

    // 把系统设备名翻成用户能一眼看懂的短名。
    // 思路：先按关键字归类（显示器/耳机/扬声器/蓝牙），再取出括号里最前面的具体型号。
    // 归类失败就原样返回，绝不猜错。
    function friendlyDeviceName(raw) {
        var desc = "" + raw
        var lower = desc.toLowerCase()

        // 括号里的第一段：VX2478-2 (HD Audio Driver for Display Audio) → VX2478-2
        var m = desc.match(/^([^(]+)\(/)
        var head = m ? m[1].trim() : desc.trim()

        var kind = ""
        if (lower.indexOf("display audio") >= 0 || lower.indexOf("hd audio driver") >= 0)
            kind = "显示器"
        else if (lower.indexOf("bluetooth") >= 0 || lower.indexOf("a2dp") >= 0)
            kind = "蓝牙"
        else if (lower.indexOf("headphone") >= 0)
            kind = "耳机"
        else if (lower.indexOf("speaker") >= 0)
            kind = "扬声器"

        if (kind === "") return desc

        // head 里已经含有类别词（Bluetooth / Headphone / Speaker）时，
        // 把它剥掉；剥完还有内容（型号）就用来标注，否则退回类别名
        var cleaned = head
                .replace(/\bbluetooth\b/gi, "")
                .replace(/\ba2dp\b/gi, "")
                .replace(/\bheadphones?\b/gi, "")
                .replace(/\bspeakers?\b/gi, "")
                .replace(/\s+/g, " ")
                .trim()
                .replace(/^[-–—,]\s*/, "")
                .trim()

        if (cleaned !== "") return kind + " (" + cleaned + ")"

        // head 无信息量：用括号里的芯片/厂商名兜底
        var m2 = desc.match(/\((.+)\)/)
        if (m2) {
            var inner = m2[1].trim()
                    .replace(/^\d+-\s*/, "")              // 去掉 "2- " 这类序号
                    .replace(/\(R\)/g, "")                // 去掉 "(R)"
                    .replace(/\s+/g, " ")
                    .trim()
            if (inner !== "" && inner.toLowerCase().indexOf("audio driver") < 0)
                return kind + " (" + inner + ")"
        }
        return kind
    }

    // 是否是蓝牙描述（供 UI 选图标用，不再每次重算）
    function isBluetoothDescription(desc) {
        var t = ("" + desc).toLowerCase()
        return t.indexOf("bluetooth") >= 0 || t.indexOf("a2dp") >= 0
    }

    // 当前实际绑定的设备 id（供 UI 高亮）
    function currentOutputDeviceId() {
        return "" + audio.device.id
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

    // source 不用绑定而用命令式赋值：蓝牙接入等场景需要重设 source 重建链路，
    // 绑定会被 imperative 赋值打断，之后切歌就失效了
    onSourceChanged: player.source = engine.source

    function play() {
        // 上次拔耳机/断蓝牙时只暂停没回落，现在用户要播了：重新按优先级选路
        if (engine.deviceStale) engine.recoverRoute()
        engine.playing = true
        player.play()
    }

    // 启动即按优先级对齐一次输出设备（手动档位优先，其次蓝牙，最后系统默认）。
    // 不这么做的话，AudioOutput 会保持 Qt 的初始绑定，
    // 直到设备列表发生变化才触发第一次选路
    Component.onCompleted: {
        var target = null
        if (engine.manualMode) target = findDeviceById(engine.outputMode)
        if (!target) target = bluetoothDevice()
        if (!target) target = mediaDevices.defaultAudioOutput
        if (target && ("" + target.id) !== "") {
            audio.device = target
            engine.activeDeviceId = "" + target.id
        }
    }

    function pause() {
        engine.playing = false
        player.pause()
    }

    function toggle() {
        if (engine.playing) engine.pause()
        else engine.play()
    }

    function stop() {
        engine.playing = false
        player.stop()
    }

    // 播完当前曲目后从头再来（用于单曲循环）
    function replay() {
        engine.playing = true
        player.setPosition(0)
        player.play()
    }

    function seekToMs(ms) {
        if (!player.seekable) return
        var total = player.duration
        var target = Math.max(0, ms)
        if (total > 0) target = Math.min(target, total - 200)
        player.setPosition(target)
    }

    function formatMs(ms) {
        if (!ms || ms < 0) ms = 0
        var total = Math.floor(ms / 1000)
        var m = Math.floor(total / 60)
        var s = total % 60
        return m + ":" + (s < 10 ? "0" + s : "" + s)
    }

    // ---------- 输出设备路由（蓝牙耳机 / 有线耳机等） ----------
    // 系统音频流在创建时就绑定了输出设备：播放中接入耳机，原有流不会自动迁移。
    // 这里监听设备变化，显式切换并重建链路。
    //
    // 选路优先级：
    //   手动档位（outputMode = 具体设备 id）→ 以用户选择为准
    //   Auto 档位（默认）：
    //     1. 蓝牙耳机在线且不是当前设备 → 抢过去（**蓝牙优先**）
    //     2. 否则 → 跟随系统默认设备（有线耳机 / 扬声器）
    //
    // 为什么 Auto 不能只"跟随系统默认"：有线 + 蓝牙同时连接时，系统默认可能是有线，
    // 但用户期望走蓝牙（用户报的 bug："有线和蓝牙同时连接，蓝牙耳机没有声音"）。
    MediaDevices {
        id: mediaDevices
    }

    Connections {
        target: mediaDevices
        function onAudioOutputsChanged() {
            // 设备增减都要让 UI 刷新候选列表
            engine.outputDevicesChanged()
            // 重建链路会连带刷新设备列表，此时必须忽略，否则自激
            if (engine.rebinding) return
            // Windows 后端在流启动瞬间会连续上报多次设备刷新，
            // 用防抖窗口合并成一次，避免播放刚起就被反复打断
            routeDebounce.restart()
        }
    }

    // 系统默认输出变化（用户插拔有线耳机、在系统里切换输出）也要跟随
    Connections {
        target: mediaDevices
        function onDefaultAudioOutputChanged() {
            if (engine.rebinding) return
            routeDebounce.restart()
        }
    }

    // 设备刷新防抖：窗口内多次变化只处理最后一次
    Timer {
        id: routeDebounce
        interval: 120
        repeat: false
        onTriggered: engine.refreshAudioRoute()
    }

    // 设备是否仍存在于系统列表中
    function isDeviceAlive(deviceId) {
        if (deviceId === "") return false
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            if ("" + outputs[i].id === deviceId) return true
        }
        return false
    }

    // 当前绑定设备是否还在系统设备列表里
    function currentDeviceAlive() {
        return isDeviceAlive("" + audio.device.id)
    }

    // 是否是蓝牙输出设备（按描述 / id 关键字识别）
    function isBluetoothDevice(device) {
        var text = ("" + device.description + " " + device.id).toLowerCase()
        return text.indexOf("bluetooth") >= 0 || text.indexOf("a2dp") >= 0
    }

    // 找到在线蓝牙设备（找不到返回 null）
    function bluetoothDevice() {
        var outputs = mediaDevices.audioOutputs
        for (var i = 0; i < outputs.length; ++i) {
            if (isBluetoothDevice(outputs[i])) return outputs[i]
        }
        return null
    }

    // 解析当前应该使用的输出设备。
    // 返回 null 表示「无需变更」，调用方不做任何动作。
    //
    // allowFallback：
    //   false（被动刷新，refreshAudioRoute 调用）—— 当前设备消失时**不主动回落**，
    //          只暂停并标记失效，避免"拔耳机瞬间声音静默跳到扬声器"
    //   true （主动恢复，recoverRoute 调用）—— 当前设备消失时**允许回落**到默认设备，
    //          否则用户点播放会保持在一个已拔掉的设备上，表现为"没声音"
    function resolveTargetDevice(allowFallback) {
        var curId = "" + audio.device.id

        // ⓪ 手动档位：用户指定了具体设备 → 以它为准
        if (engine.manualMode) {
            var wanted = findDeviceById(engine.outputMode)
            if (wanted) {
                if ("" + wanted.id === curId) return null      // 已经在用，不动
                return wanted                                   // 切过去（含"用户改了选择"）
            }
            // 指定设备不在线：不强行切换，走后面的 Auto 逻辑过渡，等它回来再切
        }

        // ① 蓝牙在线且当前没用它 → 抢过去（蓝牙优先）
        var bt = bluetoothDevice()
        if (bt && "" + bt.id !== curId) return bt

        // ② 已经在用蓝牙：保持不动
        if (bt && "" + bt.id === curId) return null

        // ③ 当前绑定的设备已消失（蓝牙断开 / 有线耳机拔出）
        if (curId !== "" && !currentDeviceAlive()) {
            // 被动刷新时先不回落，交给 refreshAudioRoute 走"暂停 + 标记失效"；
            // 用户主动点播放时（allowFallback）才真正回落到默认设备
            if (!allowFallback) return null
        }

        // ④ 跟随系统默认（用户插了有线耳机 / 设备消失后回落）
        var def = mediaDevices.defaultAudioOutput
        if (("" + def.id) === "") return null
        if (curId === "" || curId !== "" + def.id) return def
        return null
    }

    // force：忽略快速返回，强制重新选路（用户主动改档位时用）
    function refreshAudioRoute(force) {
        if (engine.rebinding) return

        var curId = "" + audio.device.id
        var curAlive = currentDeviceAlive()
        var bt = bluetoothDevice()
        var btId = bt ? "" + bt.id : ""
        var defId = "" + mediaDevices.defaultAudioOutput.id

        if (!force) {
            // 快速返回：当前设备在线，且没有任何"需要重新选路"的信号。
            // 三个信号会让我们必须继续往下走：
            //   1. 手动档位指定了别的设备
            //   2. 有蓝牙且当前没用它（蓝牙优先抢占）
            //   3. 当前设备不是系统默认（用户插了有线 / 在系统里切了输出）
            // 另外：设备已失效或处于 stale 状态时不返回
            if (curId !== "" && curAlive && !engine.deviceStale) {
                var manualWants = engine.manualMode
                        && engine.outputMode !== curId
                        && findDeviceById(engine.outputMode) !== null
                var btWantsToTake = !engine.manualMode && bt && btId !== curId
                var defChanged = defId !== "" && curId !== defId
                if (!manualWants && !btWantsToTake && !defChanged) return
            }
        }

        var target = resolveTargetDevice(false)
        if (target) {
            applyRoute(target)
            return
        }

        // 没有可切换的目标，且当前绑定的设备已消失（蓝牙断开 / 耳机拔出）。
        // 按用户要求：只暂停，不自动回落，等下次点播放再重新选路
        if (!curAlive) {
            if (engine.playing) {
                engine.playing = false
                player.pause()
            }
            engine.deviceStale = true
        }
    }

    // 用户再次播放时调用：重新选路并重建链路。
    // 这里必须允许回落（allowFallback = true）——否则拔掉耳机后点播放，
    // 设备还停在那副已拔掉的耳机上，表现就是"没有声音"
    function recoverRoute() {
        var target = resolveTargetDevice(true)
        if (!target) {
            // 无需变更：当前设备仍然可用
            engine.deviceStale = false
            return
        }
        engine.deviceStale = false
        applyRoute(target)
    }

    function applyRoute(target) {
        var targetId = "" + target.id
        if (targetId === engine.activeDeviceId) return

        engine.rebinding = true
        audio.device = target
        engine.activeDeviceId = targetId
        rebindAudio()
        engine.rebinding = false
    }

    // 重建播放链路：停流 → 重设 source → 续播，让新的音频流绑到切换后的设备
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
