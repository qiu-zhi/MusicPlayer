import QtQuick
import QtQuick.Window
import QtQuick.Controls
import QtCore
import "components"
import "js/PlayerActions.js" as Actions

Window {
    id: root
    visible: true
    width: 420
    height: 720
    title: "Music Player"
    color: Theme.bg

    readonly property string iconBase: "../assets/icons/"

    // ---------- 界面状态 ----------
    property int currentSongIndex: -1
    property string currentFile: ""
    property int playMode: 0        // 0 列表循环 / 1 单曲循环 / 2 随机
    property bool inLyricsMode: false
    property int currentLyricIndex: -1
    // 点歌时所在的列表，上一首/下一首只在这个范围里走
    property var playQueue: []
    property bool scanning: false
    readonly property string scanStatusText: "正在扫描曲库…"

    // 原生侧桥接（main.cpp 注入）。整个应用都依赖它，所有 null 判断集中在这一处
    readonly property var fs: typeof folderScanner !== "undefined" ? folderScanner : null

    // 输出设备（安卓入口已隐藏，见 MoreMenu）
    property string outputMode: "auto"
    property var outputDevices: []

    // 安全视图高度 = 窗口高度减系统栏，播放列表两档高度都以它为基准
    readonly property real safeViewHeight: Math.max(1,
            height - SafeArea.margins.top - SafeArea.margins.bottom)

    // 逻辑层上下文：js/PlayerActions.js 只认这几个对象。
    // 在 Component.onCompleted 里赋值 —— 那时所有子对象都已就绪
    property var ctx: null

    // ---------- 播放偏好持久化 ----------
    Settings {
        id: appSettings
        location: configFile
        category: "player"
        property int playMode: 0
        property string outputMode: "auto"
    }

    // ---------- 数据 / 播放 / 歌词 ----------
    PlaylistStore {
        id: store
    }

    PlaybackEngine {
        id: engine

        onEnded: Actions.handleSongEnd(root.ctx)
        onProgressChanged: function(positionMs) { Actions.syncLyric(root.ctx, positionMs) }
        onPlaybackError: function(file, message) { Actions.handlePlaybackError(root.ctx, file, message) }
    }

    LyricsLoader {
        id: lyricLoader
    }

    Connections {
        target: store
        function onSongsChanged() { Actions.syncWithLibrary(root.ctx) }
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
    // 占位歌词必须是只初始化一次的常量，写在三元里会让 ListView 反复重建（界面闪）
    readonly property var placeholderLyrics: [{ timeMs: 0, text: "♪ 暂无歌词 ♪" }]
    readonly property var displayLyrics: (lyricLoader.loaded && lyricLoader.lines.length > 0)
        ? lyricLoader.lines
        : placeholderLyrics
    readonly property string currentLyricText: {
        var lines = lyricLoader.lines
        var i = root.currentLyricIndex
        if (!lyricLoader.loaded || !lines || i < 0 || i >= lines.length) return ""
        return lines[i].text
    }
    readonly property bool hasSongs: store.count > 0

    // ---------- 播放控制（逻辑都在 js/PlayerActions.js） ----------
    function playFromList(file, likedView) { Actions.playFromList(root.ctx, file, likedView) }
    function openExternal(url) { Actions.openExternal(root.ctx, url) }
    function playNext(autoplay) { Actions.playNext(root.ctx, autoplay) }
    function playPrev() { Actions.playPrev(root.ctx) }
    function togglePlay() { Actions.togglePlay(root.ctx) }

    // ---------- 全局轻提示 ----------
    function showToast(message) {
        toast.text = message
    }

    // ---------- 输出设备选择 ----------
    function setOutputSheetVisible(visible) {
        if (visible) {
            root.refreshOutputDevices()
            outputDeviceSheet.open()
        } else {
            outputDeviceSheet.close()
        }
    }

    function refreshOutputDevices() {
        root.outputDevices = engine.availableOutputDevices()
        root.outputMode = engine.outputMode
    }

    function deviceName(deviceId) {
        for (var i = 0; i < root.outputDevices.length; ++i) {
            var d = root.outputDevices[i]
            if ("" + d.id === deviceId) return "" + (d.label || d.description)
        }
        return "指定设备"
    }

    // ---------- 播放列表面板 ----------
    function setPlaylistVisible(visible) {
        if (visible) {
            playlistPanel.resetState()
            playlistPanel.open()
        } else {
            playlistPanel.close()
        }
    }

    // ---------- 菜单动作 ----------
    function addSongs() {
        addMusicDialogs.pickFiles()
    }

    // ---------- 系统「打开方式」进来的地址 ----------
    Connections {
        target: fileOpenRelay
        function onFileOpenRequested(url) { root.openExternal(url) }
    }

    // ---------- 文件夹扫描结果 ----------
    Connections {
        target: root.fs
        function onScanFinished(files) { Actions.handleScanFinished(root.ctx, files) }
    }

    Component.onCompleted: {
        // 先备好逻辑层上下文：下面的 store.load() 会触发 songsChanged
        root.ctx = {
            root: root,
            store: store,
            engine: engine,
            lyrics: lyricLoader,
            fs: root.fs
        }
        root.playMode = appSettings.playMode
        // 恢复上次的输出档位，引擎会在自己的 onCompleted 里做首次选路
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
    TopBar {
        id: topBar
        width: parent.width - 32
        height: 48
        anchors.top: parent.top
        anchors.topMargin: 16 + root.SafeArea.margins.top   // 避开状态栏 / 挖孔
        anchors.left: parent.left
        anchors.leftMargin: 16
        iconBase: root.iconBase
        showBack: root.inLyricsMode
        onBackClicked: root.inLyricsMode = false
        onMenuClicked: moreMenu.open()
    }

    MoreMenu {
        id: moreMenu
        iconBase: root.iconBase
        // 安卓隐藏「输出设备」：播放走原生、路由由系统管，且无公开 API 可指定设备
        showOutputDevice: !engine.useNative
        anchorX: root.width - 12
        anchorY: topBar.y + topBar.height + 4

        onAddSongRequested: root.addSongs()
        onScanFolderRequested: addMusicDialogs.pickFolder()
        onOutputDeviceRequested: root.setOutputSheetVisible(true)
        onAboutRequested: aboutPopup.open()
    }

    AboutDialog {
        id: aboutPopup
        anchors.centerIn: parent
    }

    AddMusicDialogs {
        id: addMusicDialogs
        onFilesPicked: function(urls) { Actions.handlePickedFiles(root.ctx, urls) }
        onFolderPicked: function(folderUrl) { Actions.handlePickedFolder(root.ctx, folderUrl) }
    }

    // ---------- 输出设备选择面板 ----------
    OutputDeviceSheet {
        id: outputDeviceSheet
        width: root.width
        safeViewHeight: root.safeViewHeight
        listBottomMargin: root.SafeArea.margins.bottom
        selectedId: root.outputMode
        devices: root.outputDevices

        onDeviceSelected: function(deviceId, mode) {
            root.setOutputSheetVisible(false)
            root.outputMode = deviceId
            appSettings.outputMode = deviceId
            if (mode === "manual") {
                engine.setOutputMode(deviceId)
                root.showToast("已切换到 " + root.deviceName(deviceId))
            } else {
                engine.setOutputMode("auto")
                root.showToast("输出设备：自动")
            }
        }
    }

    Connections {
        target: engine
        function onOutputDevicesChanged() {
            // 面板开着才刷新，以 Drawer 的真实状态为准，不另设镜像变量
            if (outputDeviceSheet.opened) root.refreshOutputDevices()
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
            onAddMusicRequested: root.addSongs()
        }

        LyricsPage {
            id: lyricsPage
            anchors.fill: parent
            opacity: root.inLyricsMode ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

            title: root.currentTitle
            subtitle: root.currentSubtitle
            lyrics: root.displayLyrics
            currentIndex: root.currentLyricIndex

            onSeekRequested: function(timeMs) {
                if (lyricLoader.loaded && engine.durationMs > 0) engine.seekToMs(timeMs)
            }
        }
    }

    // ---------- 底部控制栏 ----------
    Item {
        id: controlsBar
        width: parent.width
        height: 112
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14 + root.SafeArea.margins.bottom   // 避开手势条

        PlayerControls {
            id: controls
            width: Math.min(parent.width, 372)
            x: (parent.width - width) / 2
            height: parent.height
            playing: root.isPlaying
            progress: root.playbackProgress
            currentTime: root.currentTimeText
            totalTime: root.totalTimeText
            playMode: root.playMode
            busy: root.scanning
            statusText: root.scanStatusText

            onPlayToggled: root.togglePlay()
            onPreviousClicked: root.playPrev()
            onNextClicked: root.playNext(true)
            // 曲库忙时点了切歌：按钮已置灰，给一句为什么，别让点击无声无息
            onSwitchBlocked: root.showToast(root.scanStatusText)
            onSeekTo: function(value) {
                if (engine.durationMs > 0) engine.seekToMs(Math.floor(value * engine.durationMs))
            }
            onPlayModeCycled: {
                root.playMode = (root.playMode + 1) % 3
                appSettings.playMode = root.playMode
            }
            onPlaylistToggled: root.setPlaylistVisible(!playlistPanel.opened)
        }
    }

    // ---------- 播放列表面板（Drawer，兼音乐库管理） ----------
    PlaylistPanel {
        id: playlistPanel
        width: root.width
        safeViewHeight: root.safeViewHeight
        listBottomMargin: root.SafeArea.margins.bottom
        allSongs: store.model
        likedSongs: store.likedSongs
        currentFile: root.currentFile

        onItemClicked: function(file, likedView) {
            root.playFromList(file, likedView)
            root.setPlaylistVisible(false)
        }

        // 删除语义随列表区分：全部 → 移出列表；喜欢 → 取消喜欢
        onRemoveRequested: function(files, likedView) {
            if (likedView) {
                var unliked = store.unlikeFiles(files)
                if (unliked > 0) root.showToast("已取消喜欢 " + unliked + " 首")
            } else {
                var removed = store.removeFiles(files)
                if (removed > 0) root.showToast("已从列表移除 " + removed + " 首")
            }
        }

        onAddMusicRequested: {
            root.setPlaylistVisible(false)
            root.addSongs()
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
