.pragma library

// 播放 / 歌单逻辑。只放纯逻辑，界面对象通过 ctx 传进来：
//   ctx = { root, store, engine, lyrics, fs }
// Main.qml 里只留属性、绑定和信号接线。
//
// 改 stepQueue 后跑 node tools/verify_stepqueue.js（直接加载本文件比对）。

// 一次「添加歌曲」最多收多少首。
//
// 这个数字不是随意定的，两头都有硬约束：
//   · Windows：Qt 的 FileDialog 层没有条数上限（QWindowsNativeOpenFileDialog 全量遍历
//     IShellItemArray），真正贵的是入库：每首都要 parseFileName + ListModel.append，
//     5000 首会冻结好几秒（已修掉 O(N²) 的探测队列，但仍随 N 线性增长）。
//   · Android：选中的每个 Uri 都要 takePersistableUriPermission。系统对每个 app 的
//     持久授权有上限 —— Android 10 及以下是 128 个，Android 11+ 是 512 个。超出的
//     文件拿不到持久权限，重启后就成了「失效曲目」。另外结果集是通过 ClipData 走
//     Binder 事务返回的（单次约 1MB），选几千个有可能让系统对话框直接失败。
//
// 300 是两头都不撞的值：Windows 上入库无感，安卓上单次远低于 512。
// 歌曲数量大时更该用「扫描文件夹」—— 一个目录只占 1 个持久授权。
var MAX_IMPORT_FILES = 300

// 批量入库（选择器已限定音频类型，trusted 跳过后缀校验，兼容无扩展名的 SAF 地址）
function handlePickedFiles(ctx, urls) {
    if (!urls || urls.length === 0) return

    var truncated = urls.length > MAX_IMPORT_FILES
    var list = truncated ? Array.prototype.slice.call(urls, 0, MAX_IMPORT_FILES) : urls

    // 逐个补一次持久读取权限：Qt 的文件对话框在安卓上已经授过权，
    // 这里是覆盖「歌已在库、但授权早就失效」的场景（幂等，重复调用只更新时间）
    if (ctx.fs) {
        for (var i = 0; i < list.length; ++i)
            ctx.fs.keepPermission(list[i])
    }

    var report = ctx.store.addFiles(list, true)

    if (truncated) {
        ctx.root.showToast("一次最多添加 " + MAX_IMPORT_FILES + " 首，本次已添加前 "
                           + list.length + " 首")
    } else if (report.added > 0) {
        var msg = "已添加 " + report.added + " 首"
        if (report.duplicate > 0) msg += "，跳过重复 " + report.duplicate + " 首"
        if (report.invalid > 0) msg += "，忽略非音频 " + report.invalid + " 个"
        ctx.root.showToast(msg)
    } else if (report.duplicate > 0) {
        ctx.root.showToast("这些歌曲都已在音乐库里了")
    } else {
        ctx.root.showToast("没有可添加的音频文件")
    }
}

// 当前播放范围：过滤掉已删除的曲目；当前歌不在队列里（比如取消了喜欢）就退回全部
function effectiveQueue(ctx) {
    var root = ctx.root
    var q = root.playQueue
    if (q && q.length > 0 && q.indexOf(root.currentFile) >= 0) {
        var valid = []
        for (var i = 0; i < q.length; ++i) {
            if (ctx.store.indexOfFile(q[i]) >= 0) valid.push(q[i])
        }
        if (valid.length > 0 && valid.indexOf(root.currentFile) >= 0) return valid
    }
    return ctx.store.allFiles()
}

// 点一首歌。skipCheck：调用方已确认文件存在，省一次系统查询
function selectSong(ctx, index, autoplay, skipCheck) {
    var root = ctx.root
    var store = ctx.store
    if (index < 0 || index >= store.count) return
    var song = store.songAt(index)
    if (!song) return

    // 先确认文件还在：被外部删掉的直接移出列表，不进「界面在播放、其实没声音」的假状态
    if (!skipCheck && purgeIfMissing(ctx, song.file)) return

    var sameSong = (root.currentSongIndex === index) && (root.currentFile === song.file)
    root.currentSongIndex = index
    root.currentFile = song.file
    root.currentLyricIndex = -1
    if (ctx.lyrics.source !== song.file) ctx.lyrics.source = song.file

    if (sameSong) {
        if (autoplay) ctx.engine.replay()
        return
    }
    ctx.engine.switchTo(song.file, autoplay)
}

// 从列表点歌：用点歌时所在的列表决定后续上一首/下一首的范围
function playFromList(ctx, file, likedView) {
    var index = ctx.store.indexOfFile(file)
    if (index < 0) return
    ctx.root.playQueue = likedView ? ctx.store.likedFiles() : ctx.store.allFiles()
    selectSong(ctx, index, true)
}

// 从其他应用「用本播放器打开」进来：收进歌单后直接播
function openExternal(ctx, url) {
    var index = ctx.store.addExternalFile(url)
    if (index < 0) return
    ctx.root.inLyricsMode = false
    ctx.root.setPlaylistVisible(false)
    ctx.root.playQueue = ctx.store.allFiles()
    selectSong(ctx, index, true)
}

// 队列切歌。dir：+1 下一首 / -1 上一首；autoplay：拿到有效曲目后是否直接播。
// 队列里可能混着已被删掉的曲目，撞上就剔掉再往前找，否则会停在这首上无声播放
function stepQueue(ctx, dir, autoplay) {
    var root = ctx.root
    var store = ctx.store
    if (store.count === 0) return
    for (var attempt = 0; attempt < 64; ++attempt) {
        var queue = effectiveQueue(ctx)
        if (queue.length === 0) return
        var cur = queue.indexOf(root.currentFile)
        var targetFile
        if (root.playMode === 2) {
            // 随机：下一首要避开当前曲目，否则可能原地不动
            var pick = Math.floor(Math.random() * queue.length)
            if (dir > 0 && queue.length > 1 && pick === cur)
                pick = (pick + 1) % queue.length
            targetFile = queue[pick]
        } else {
            targetFile = queue[cur < 0 ? 0 : (cur + dir + queue.length) % queue.length]
        }
        if (purgeIfMissing(ctx, targetFile)) continue
        var index = store.indexOfFile(targetFile)
        if (index < 0) continue
        selectSong(ctx, index, autoplay, true)
        return
    }
}

// autoplay 由调用方决定：列表循环播完要继续播，用户点「下一首」也是播
function playNext(ctx, autoplay) {
    stepQueue(ctx, 1, autoplay !== false)
}

function playPrev(ctx) {
    stepQueue(ctx, -1, true)
}

function handleSongEnd(ctx) {
    if (ctx.store.count === 0) return
    if (ctx.root.playMode === 1) {
        ctx.engine.replay()
        return
    }
    playNext(ctx, true)
}

function togglePlay(ctx) {
    var root = ctx.root
    var store = ctx.store
    if (store.count === 0) {
        root.addSongs()
        return
    }
    if (root.currentSongIndex < 0) {
        root.playQueue = store.allFiles()
        selectSong(ctx, 0, true)
        return
    }
    // 当前曲目可能已被外部删除：先核实。失效时上面这次移除已让 syncWithLibrary
    // 把焦点对齐到邻近曲目，直接开播即可
    if (purgeIfMissing(ctx, root.currentFile)) {
        if (store.count > 0 && root.currentFile !== "") ctx.engine.play()
        return
    }
    ctx.engine.toggle()
}

function syncLyric(ctx, positionMs) {
    var loader = ctx.lyrics
    if (!loader.loaded) {
        if (ctx.root.currentLyricIndex !== -1) ctx.root.currentLyricIndex = -1
        return
    }
    var index = loader.indexAt(positionMs)
    if (index !== ctx.root.currentLyricIndex) ctx.root.currentLyricIndex = index
}

// 曲库增删后重新对齐当前歌曲
function syncWithLibrary(ctx) {
    var root = ctx.root
    var store = ctx.store
    if (store.count === 0) {
        ctx.engine.stop()
        ctx.engine.source = ""
        ctx.lyrics.source = ""
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
    // 当前歌被删了：从邻近位置接上
    var next = Math.min(Math.max(root.currentSongIndex, 0), store.count - 1)
    selectSong(ctx, next, ctx.engine.playing)
}

// 文件是否仍可访问：安卓走 ContentResolver 试打开，桌面走文件系统。
// 探测出错一律按「可用」处理，不能因为探测失败就删用户的歌
function fileAvailable(ctx, fileUrl) {
    if (!fileUrl) return false
    if (!ctx.fs) return true
    try {
        return ctx.fs.fileExists(fileUrl) === true
    } catch (e) {
        return true
    }
}

// 失效就提示并从曲库移除；返回 true 表示已移除
function purgeIfMissing(ctx, fileUrl) {
    if (fileAvailable(ctx, fileUrl)) return false
    var title = ""
    var index = ctx.store.indexOfFile(fileUrl)
    if (index >= 0) {
        var song = ctx.store.songAt(index)
        if (song) title = song.title
    }
    // 移除属于破坏性操作，日志留 logcat 便于回溯是哪首、什么时候被清掉的
    console.warn("[purgeIfMissing] 判定文件不存在，从曲库移除:", fileUrl, "|", title)
    ctx.store.removeFile(fileUrl)
    ctx.root.showToast(title !== "" ? "「" + title + "」文件已不存在，已从列表移除"
                                    : "文件已不存在，已从列表移除")
    return true
}

// 播放中途失败（最常见是源文件被外部删除）：真没了就清出列表，否则只提示不改数据
function handlePlaybackError(ctx, file, message) {
    if (!file) return
    if (message) console.warn("[playbackError]", message, file)
    ctx.engine.stop()
    if (!purgeIfMissing(ctx, file))
        ctx.root.showToast("这首歌无法播放")
}

// 单曲入库（选择器已限定音频类型，trusted 跳过后缀校验，兼容无扩展名的 SAF 地址）
// 扫描文件夹（异步，避免阻塞界面）
function handlePickedFolder(ctx, folderUrl) {
    if (ctx.root.scanning) return
    ctx.root.scanning = true
    ctx.root.showToast("正在扫描文件夹…")
    ctx.fs.scanFolderAsync(folderUrl)
}

// 扫描结果入库
function handleScanFinished(ctx, files) {
    ctx.root.scanning = false
    var report = ctx.store.addFiles(files, true)
    if (report.added > 0)
        ctx.root.showToast("已添加 " + report.added + " 首")
    else if (files.length > 0)
        ctx.root.showToast("文件夹里的歌曲都已在曲库中")
    else
        ctx.root.showToast("文件夹里没有找到音频文件")
}
