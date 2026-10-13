import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtCore
import "components"

Window {
    id: root
    visible: true
    width: 420
    height: 720
    title: "Music Player"
    // 配色取自唱机素材：浅灰机身 + 近黑唱片 + 橙色标签
    color: "#E3E6E9"

    // 图标路径前缀（Image 的相对路径以所在组件文件为基准解析）
    readonly property string iconBase: "../assets/icons/"

    // ---------- 界面状态 ----------
    property int currentSongIndex: -1
    property string currentFile: ""
    property int playMode: 0        // 0 列表循环 / 1 单曲循环 / 2 随机播放
    property bool showPlaylist: false
    property bool inLyricsMode: false
    property bool inLibraryMode: false
    property int currentLyricIndex: -1
    // 当前播放范围（点歌时所在列表的 file 序列），上一首/下一首只在这个范围内走
    property var playQueue: []

    // ---------- 输出设备选择 ----------
    property bool showOutputSheet: false
    // 输出档位："auto"（蓝牙优先）或具体设备 id（手动指定）
    property string outputMode: "auto"
    property string outputDeviceId: ""
    // 设备列表快照，供选择面板展示
    property var outputDevices: []
    property real outputSheetHideProgress: 1   // 0 停靠 / 1 收起

    function setOutputSheetVisible(visible) {
        root.showOutputSheet = visible
        root.outputSheetHideProgress = visible ? 0 : 1
        if (visible) root.refreshOutputDevices()
    }

    Behavior on outputSheetHideProgress {
        NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
    }

    // 从引擎拉取设备列表并同步当前档位
    function refreshOutputDevices() {
        root.outputDevices = engine.availableOutputDevices()
        root.outputMode = engine.outputMode
        root.outputDeviceId = engine.currentOutputDeviceId()
    }

    // 按设备 id 取显示名，用于切换后的提示（优先用引擎翻译过的可读名）
    function deviceName(deviceId) {
        for (var i = 0; i < root.outputDevices.length; ++i) {
            if ("" + root.outputDevices[i].id === deviceId) {
                var d = root.outputDevices[i]
                return "" + (d.label || d.description)
            }
        }
        return "指定设备"
    }

    // ---------- 播放偏好持久化 ----------
    Settings {
        id: appSettings
        category: "player"
        property int playMode: 0
        property string outputMode: "auto"
        property string outputDeviceId: ""
    }

    // ---------- 数据 / 播放 / 歌词 ----------
    PlaylistStore {
        id: store
    }

    PlaybackEngine {
        id: engine

        onEnded: root.handleSongEnd()
        onProgressChanged: function(positionMs) { root.syncLyric(positionMs) }
        onPlaybackError: function(file, message) { root.handlePlaybackError(file, message) }
    }

    LyricsLoader {
        id: lyricLoader
    }

    Connections {
        target: store
        function onSongsChanged() { root.syncWithLibrary() }
    }

    // ---------- 当前歌曲信息（跟随数据变化自动刷新） ----------
    readonly property var currentSong: {
        store.revision
        if (root.currentSongIndex < 0 || root.currentSongIndex >= store.count) return null
        return store.songAt(root.currentSongIndex)
    }
    readonly property bool isPlaying: engine.playing
    readonly property bool isLiked: currentSong ? currentSong.liked : false
    readonly property string currentTitle: currentSong ? currentSong.title : "还没有选择歌曲"
    readonly property string currentSubtitle: currentSong
        ? (currentSong.album ? currentSong.artist + " · " + currentSong.album : currentSong.artist)
        : "从音乐库添加本地歌曲"
    readonly property real playbackProgress: engine.durationMs > 0
        ? Math.min(1, engine.positionMs / engine.durationMs) : 0
    readonly property string currentTimeText: engine.formatMs(engine.positionMs)
    readonly property string totalTimeText: engine.durationMs > 0
        ? engine.formatMs(engine.durationMs)
        : (currentSong ? currentSong.durationText : "0:00")
    readonly property var displayLyrics: (lyricLoader.loaded && lyricLoader.lines.length > 0)
        ? lyricLoader.lines
        : [{ timeMs: 0, text: "♪ 暂无歌词 ♪" }]
    // 当前正在唱的那句，播放页直接展示
    readonly property string currentLyricText: {
        var lines = lyricLoader.lines
        var i = root.currentLyricIndex
        if (!lyricLoader.loaded || !lines || i < 0 || i >= lines.length) return ""
        return lines[i].text
    }
    readonly property bool hasSongs: store.count > 0

    // ---------- 播放控制 ----------
    // skipCheck：调用方已经确认过文件存在时传 true，省掉一次系统查询
    function selectSong(index, autoplay, skipCheck) {
        if (index < 0 || index >= store.count) return
        var song = store.songAt(index)
        if (!song) return

        // 播放前先确认文件还在：被外部删掉的曲目直接提示并移出列表，
        // 不能进到「界面显示在播放、实际一点声音都没有」的假播放状态
        if (!skipCheck && root.purgeIfMissing(song.file)) return

        var sameSong = (root.currentSongIndex === index) && (root.currentFile === song.file)
        root.currentSongIndex = index
        root.currentFile = song.file
        root.currentLyricIndex = -1

        if (lyricLoader.source !== song.file) lyricLoader.source = song.file

        if (sameSong) {
            if (autoplay) engine.replay()
            return
        }
        engine.source = song.file
        if (autoplay) engine.play()
        else engine.stop()
    }

    // 取当前播放范围；过滤掉已被删除的曲目；当前歌曲不在队列里（如取消了喜欢）就退回全部歌曲
    function effectiveQueue() {
        var q = root.playQueue
        if (q && q.length > 0 && q.indexOf(root.currentFile) >= 0) {
            var valid = []
            for (var i = 0; i < q.length; ++i) {
                if (store.indexOfFile(q[i]) >= 0) valid.push(q[i])
            }
            if (valid.length > 0 && valid.indexOf(root.currentFile) >= 0) return valid
        }
        return store.allFiles()
    }

    // 从列表点歌：按点歌时所在的列表决定后续上一首/下一首的范围
    function playFromList(file, likedView) {
        var index = store.indexOfFile(file)
        if (index < 0) return
        root.playQueue = likedView ? store.likedFiles() : store.allFiles()
        root.selectSong(index, true)
    }

    // 从其他应用「用本播放器打开」进入：收进歌单后直接播放
    function openExternal(url) {
        var index = store.addExternalFile(url)
        if (index < 0) return
        root.inLyricsMode = false
        root.inLibraryMode = false
        root.setPlaylistVisible(false)
        root.playQueue = store.allFiles()
        root.selectSong(index, true)
    }

    // 系统「打开方式」的地址经 C++ 中转到这里
    Connections {
        target: fileOpenRelay
        function onFileOpenRequested(url) { root.openExternal(url) }
    }

    // ---------- 切歌 ----------
    // 队列里可能混着已被外部删除的曲目：撞上就剔掉再往前找，
    // 否则「下一首」会反复停在这首上无声播放
    // dir：+1 下一首 / -1 上一首；autoplay：拿到有效曲目后是否直接播放
    function stepQueue(dir, autoplay) {
        if (store.count === 0) return
        for (var attempt = 0; attempt < 64; ++attempt) {
            var queue = root.effectiveQueue()
            if (queue.length === 0) return
            var cur = queue.indexOf(root.currentFile)
            var targetFile
            if (root.playMode === 2) {
                // 随机播放：下一首避开当前曲目（否则「下一首」可能原地不动）
                var pick = Math.floor(Math.random() * queue.length)
                if (dir > 0 && queue.length > 1 && pick === cur)
                    pick = (pick + 1) % queue.length
                targetFile = queue[pick]
            } else {
                targetFile = queue[cur < 0 ? 0 : (cur + dir + queue.length) % queue.length]
            }
            if (root.purgeIfMissing(targetFile)) continue
            var index = store.indexOfFile(targetFile)
            if (index < 0) continue
            root.selectSong(index, autoplay, true)
            return
        }
    }

    // 「下一首」：自动播放在调用方可控（列表循环结束时需要带 autoplay 继续）
    function playNext(autoplay) {
        root.stepQueue(1, autoplay !== false)
    }

    // 「上一首」：用户主动切歌，恒为播放
    function playPrev() {
        root.stepQueue(-1, true)
    }

    function handleSongEnd() {
        if (store.count === 0) return
        if (root.playMode === 1) {
            engine.replay()
            return
        }
        root.playNext(true)
    }

    function togglePlay() {
        if (store.count === 0) {
            root.inLibraryMode = true
            return
        }
        if (root.currentSongIndex < 0) {
            root.playQueue = store.allFiles()
            root.selectSong(0, true)
            return
        }
        // 当前曲目可能已被外部删除：先核实。失效时上面这次移除已经让
        // syncWithLibrary 把焦点对齐到了邻近曲目，直接开播即可
        if (root.purgeIfMissing(root.currentFile)) {
            if (store.count > 0 && root.currentFile !== "") engine.play()
            return
        }
        engine.toggle()
    }

    function syncLyric(positionMs) {
        if (!lyricLoader.loaded) {
            if (root.currentLyricIndex !== -1) root.currentLyricIndex = -1
            return
        }
        var index = lyricLoader.indexAt(positionMs)
        if (index !== root.currentLyricIndex) root.currentLyricIndex = index
    }

    // 音乐库增删后重新对齐当前歌曲
    function syncWithLibrary() {
        if (store.count === 0) {
            engine.stop()
            engine.source = ""
            lyricLoader.source = ""
            root.currentSongIndex = -1
            root.currentFile = ""
            root.currentLyricIndex = -1
            root.playQueue = []
            return
        }
        var index = store.indexOfFile(root.currentFile)
        if (index >= 0) {
            root.currentSongIndex = index
            return
        }
        // 当前歌曲被删掉了，从邻近位置接上
        var next = Math.min(Math.max(root.currentSongIndex, 0), store.count - 1)
        root.selectSong(next, engine.playing)
    }

    // ---------- 全局轻提示 ----------
    function showToast(message) {
        toast.text = message
    }

    // ---------- 失效曲目拦截 ----------
    // 文件是否仍可访问：Android 走 ContentResolver 试打开，桌面走文件系统。
    // 检查本身出错时一律按「可用」处理，不能因为探测失败就删用户的歌
    function fileAvailable(fileUrl) {
        if (!fileUrl) return false
        if (typeof folderScanner === "undefined") return true
        try {
            return folderScanner.fileExists(fileUrl) === true
        } catch (e) {
            return true
        }
    }

    // 失效就提示并从曲库移除；返回 true 表示已移除
    function purgeIfMissing(fileUrl) {
        if (root.fileAvailable(fileUrl)) return false
        var title = ""
        var index = store.indexOfFile(fileUrl)
        if (index >= 0) {
            var song = store.songAt(index)
            if (song) title = song.title
        }
        store.removeFile(fileUrl)
        root.showToast(title !== "" ? "「" + title + "」文件已不存在，已从列表移除"
                                    : "文件已不存在，已从列表移除")
        return true
    }

    // 播放中途失败（最常见是源文件被外部删除）：真没了就清出列表，否则只提示不改数据
    function handlePlaybackError(file, message) {
        if (!file) return
        if (message) console.warn("[playbackError]", message, file)
        engine.stop()
        if (!root.purgeIfMissing(file))
            root.showToast("这首歌无法播放")
    }

    // ---------- 播放列表面板停靠控制 ----------
    // hideProgress：0 = 停靠 / 1 = 完全收起；位移动画只挂在这个进度值上，
    // 窗口缩放仅改变面板高度、不碰进度值，因此不会触发错误的位置动画
    property real playlistHideProgress: 1

    function setPlaylistVisible(visible) {
        root.showPlaylist = visible
        root.playlistHideProgress = visible ? 0 : 1
    }

    Behavior on playlistHideProgress {
        NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
    }

    // ---------- 右上角菜单的三个动作 ----------
    // 添加单曲：单选文件，规避多选场景的问题
    function addSingleSong() {
        addMusicDialogs.pickSingleFile()
    }

    // 单曲入库（由 AddMusicDialogs 的 filePicked 信号触发）
    function handlePickedFile(fileUrl) {
        // 选择器已限定音频类型，trusted 跳过后缀校验，兼容不带扩展名的 SAF 地址
        var report = store.addFiles([fileUrl], true)
        if (report.added > 0) {
            if (typeof folderScanner !== "undefined")
                folderScanner.keepPermission(fileUrl)
            root.showToast("已添加 " + report.added + " 首")
        } else if (report.duplicate > 0) {
            root.showToast("这首歌曲已经在音乐库里了")
        } else {
            root.showToast("没有可添加的音频文件")
        }
    }

    // 扫描文件夹（由 AddMusicDialogs 的 folderPicked 信号触发）
    // 扫描可能遍历大量文件，先让提示浮层画出来再干活
    function handlePickedFolder(folderUrl) {
        root.pendingScanFolder = folderUrl
        root.showToast("正在扫描文件夹…")
        scanDeferTimer.restart()
    }

    // 待扫描的文件夹路径，供 scanDeferTimer 消费
    property string pendingScanFolder: ""

    Timer {
        id: scanDeferTimer
        interval: 60
        onTriggered: {
            var files = folderScanner.scanFolder(root.pendingScanFolder)
            var report = store.addFiles(files, true)
            if (report.added > 0)
                root.showToast("已添加 " + report.added + " 首")
            else if (files.length > 0)
                root.showToast("文件夹里的歌曲都已在曲库中")
            else
                root.showToast("文件夹里没有找到音频文件")
        }
    }
    Component.onCompleted: {
        root.playMode = appSettings.playMode
        // 恢复上次的输出档位：Auto（默认）或用户手动指定的设备。
        // 引擎拿到档位后会在自己的 onCompleted 里做首次选路
        var savedOutput = appSettings.outputMode
        if (savedOutput && savedOutput !== "") {
            engine.outputMode = savedOutput
            root.outputMode = savedOutput
        }
        store.load()
    }

    // 关闭前把播放列表落盘，避免防抖保存还没触发就退出
    onClosing: store.save()

    // ---------- 顶部栏 ----------
    Item {
        id: topBar
        width: parent.width - 32
        height: 48
        anchors.top: parent.top
        // 挖孔屏 / 状态栏区域需要避开，SafeArea 在桌面端为 0 不影响原布局
        anchors.topMargin: 16 + root.SafeArea.margins.top
        anchors.left: parent.left
        anchors.leftMargin: 16
        visible: !root.inLibraryMode

        // 返回按钮与标题互斥显示，因此都靠左对齐
        IconButton {
            id: backButton
            iconSource: root.iconBase + "chevron-down.svg"
            iconColor: "#17181A"
            iconSize: 22
            implicitWidth: 40
            implicitHeight: 40
            tooltipText: "返回播放页"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: root.inLyricsMode
            rotation: 90
            onClicked: root.inLyricsMode = false
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2
            visible: !root.inLyricsMode

            // 右上角菜单：添加单曲 / 扫描文件夹 / 关于
            IconButton {
                id: moreMenuButton
                iconSource: root.iconBase + "more-vertical.svg"
                iconColor: "#17181A"
                iconSize: 20
                implicitWidth: 40
                implicitHeight: 40
                tooltipText: "菜单"
                onClicked: moreMenu.open()
            }
        }
    }

    // ---------- 右上角下拉菜单 ----------
    MoreMenu {
        id: moreMenu
        iconBase: root.iconBase
        // 锚定在菜单按钮下方、右对齐，不用底部停靠，避免弹层被顶到屏幕外
        anchorX: root.width - 12
        anchorY: topBar.y + topBar.height + 4

        onAddSongRequested: root.addSingleSong()
        onScanFolderRequested: addMusicDialogs.pickFolder()
        onOutputDeviceRequested: root.setOutputSheetVisible(true)
        onAboutRequested: aboutPopup.open()
    }

    // ---------- 「关于」弹窗 ----------
    AboutDialog {
        id: aboutPopup
        anchors.centerIn: parent
    }

    // ---------- 文件 / 文件夹选择 ----------
    AddMusicDialogs {
        id: addMusicDialogs
        onFilePicked: function(fileUrl) { root.handlePickedFile(fileUrl) }
        onFolderPicked: function(folderUrl) { root.handlePickedFolder(folderUrl) }
    }

    // ---------- 输出设备选择面板（底部上滑） ----------
    Item {
        id: outputSheetLayer
        anchors.fill: parent
        // 收起后完全不参与命中测试，避免挡住下层交互
        visible: root.outputSheetHideProgress < 1
        z: 200

        // 半透明遮罩：点击关闭
        Rectangle {
            anchors.fill: parent
            color: "#000000"
            opacity: root.showOutputSheet ? 0.4 : 0
            Behavior on opacity { NumberAnimation { duration: 220 } }

            MouseArea {
                anchors.fill: parent
                onClicked: root.setOutputSheetVisible(false)
            }
        }

        OutputDeviceSheet {
            id: outputDeviceSheet
            width: parent.width
            height: outputDeviceSheet.sheetHeight
            anchors.bottom: parent.bottom
            anchors.bottomMargin: -height * root.outputSheetHideProgress
                                  - outputDeviceSheet.dragOffset * (1 - root.outputSheetHideProgress)
            selectedId: root.showOutputSheet ? root.outputMode : outputDeviceSheet.selectedId
            devices: root.outputDevices

            onDeviceSelected: function(deviceId, mode) {
                root.outputMode = deviceId
                appSettings.outputMode = deviceId
                if (mode === "manual") {
                    appSettings.outputDeviceId = deviceId
                    engine.setOutputMode(deviceId)
                    root.showToast("已切换到 " + root.deviceName(deviceId))
                } else {
                    appSettings.outputDeviceId = ""
                    engine.setOutputMode("auto")
                    root.showToast("输出设备：自动")
                }
                root.setOutputSheetVisible(false)
            }
            onDismissed: root.setOutputSheetVisible(false)
        }
    }

    // 引擎报告设备增减时刷新候选列表
    Connections {
        target: engine
        function onOutputDevicesChanged() {
            if (root.showOutputSheet) root.refreshOutputDevices()
        }
    }

    // ---------- 主内容区：播放视图与歌词视图叠放 ----------
    Item {
        id: contentArea
        anchors.top: topBar.bottom
        anchors.bottom: controlsBar.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 8
        visible: !root.inLibraryMode

        // 播放视图
        PlayerView {
            id: playerView
            anchors.fill: parent
            opacity: root.inLyricsMode ? 0 : 1
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            playing: root.isPlaying
            iconBase: root.iconBase
            title: root.currentTitle
            subtitle: root.currentSubtitle
            lyricText: root.currentLyricText
            hasSongs: root.hasSongs
            liked: root.isLiked

            onLikeToggled: {
                if (root.currentSongIndex >= 0) store.toggleLiked(root.currentSongIndex)
            }
            onLyricClicked: root.inLyricsMode = true
            onAddMusicRequested: root.inLibraryMode = true
        }

        // 歌词视图
        Item {
            id: lyricsPageView
            anchors.fill: parent
            opacity: root.inLyricsMode ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            Column {
                id: lyricsSongInfo
                width: parent.width - 32
                // 顶部留出返回按钮（48 高 + 16 上边距）的空间
                anchors.top: parent.top
                anchors.topMargin: 76
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 2

                Text {
                    text: root.currentTitle
                    color: "#17181A"
                    font.pixelSize: 16
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Text {
                    text: root.currentSubtitle
                    color: "#8A8D92"
                    font.pixelSize: 12
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }

            LyricsView {
                id: fullLyricsView
                anchors.top: lyricsSongInfo.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: 16
                lyrics: root.displayLyrics
                currentIndex: root.currentLyricIndex

                onLineClicked: function(index) {
                    if (!lyricLoader.loaded) return
                    var line = root.displayLyrics[index]
                    if (line && engine.durationMs > 0) engine.seekToMs(line.timeMs)
                }
            }
        }
    }

    // ---------- 底部控制栏 ----------
    Item {
        id: controlsBar
        width: parent.width
        height: 112
        anchors.bottom: parent.bottom
        // 避开底部手势导航条
        anchors.bottomMargin: 14 + root.SafeArea.margins.bottom
        visible: !root.inLibraryMode

        PlayerControls {
            id: controls
            // 与唱机同理：限制最大宽度，最大化时保持居中的窄栏布局
            width: Math.min(parent.width, 372)
            x: (parent.width - width) / 2
            height: parent.height
            playing: root.isPlaying
            progress: root.playbackProgress
            currentTime: root.currentTimeText
            totalTime: root.totalTimeText
            playMode: root.playMode

            onPlayToggled: root.togglePlay()
            onPreviousClicked: root.playPrev()
            onNextClicked: root.playNext(true)
            onSeekTo: function(value) {
                if (engine.durationMs > 0) engine.seekToMs(Math.floor(value * engine.durationMs))
            }
            onPlayModeCycled: {
                root.playMode = (root.playMode + 1) % 3
                appSettings.playMode = root.playMode
            }
            onPlaylistToggled: root.setPlaylistVisible(!root.showPlaylist)
        }
    }

    // ---------- 播放列表面板（底部上滑面板） ----------
    PlaylistPanel {
        id: playlistPanel
        // 停靠高度约为视口 55%：顶部边缘落在屏幕中线略上方
        width: parent.width
        height: Math.max(300, Math.round(parent.height * 0.55))
        anchors.bottom: parent.bottom
        // 停靠位 0；收起位 = 面板高度；下拉拖动量只在停靠态叠加，
        // 收起时拖动量同步归零，面板从拖动态平滑滑到完全隐藏
        anchors.bottomMargin: -playlistPanel.height * root.playlistHideProgress
                              - playlistPanel.dragOffset * (1 - root.playlistHideProgress)
        allSongs: store.model
        likedSongs: store.likedSongs
        currentFile: root.currentFile
        z: 100

        // 完全滑出窗口后停止构建内部列表
        visible: anchors.bottomMargin > -playlistPanel.height

        onItemClicked: function(file, likedView) {
            root.playFromList(file, likedView)
            root.setPlaylistVisible(false)
        }
        onManageRequested: {
            root.setPlaylistVisible(false)
            root.inLyricsMode = false
            root.inLibraryMode = true
        }
        onCloseRequested: root.setPlaylistVisible(false)
    }

    // 播放列表遮罩
    Rectangle {
        id: overlay
        anchors.fill: parent
        color: "#000000"
        opacity: root.showPlaylist ? 0.4 : 0
        visible: opacity > 0
        z: 99
        Behavior on opacity { NumberAnimation { duration: 250 } }
        MouseArea {
            anchors.fill: parent
            onClicked: root.setPlaylistVisible(false)
        }
    }

    // ---------- 音乐库整页覆盖层 ----------
    LibraryPage {
        id: libraryPage
        anchors.fill: parent
        z: 300
        store: store
        currentIndex: root.currentSongIndex
        opacity: root.inLibraryMode ? 1 : 0
        visible: opacity > 0
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

        onCloseRequested: root.inLibraryMode = false
        onPlayRequested: function(index) {
            root.playQueue = store.allFiles()
            root.selectSong(index, true)
            root.inLibraryMode = false
        }
    }

    // ---------- 全局轻提示 ----------
    AppToast {
        id: toast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 120
    }
}
