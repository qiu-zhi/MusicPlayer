import QtQuick
import QtMultimedia
import "../js/Format.js" as Format

// 播放列表数据源：负责歌曲增删、音频元数据探测，以及本地持久化
// 角色：file / title / artist / album / durationMs / durationText / liked / probed / format
Item {
    id: store
    width: 0
    height: 0

    // 任意数据（含元数据、喜欢状态、增删）变化时自增，供外部绑定刷新
    property int revision: 0
    // 只在「喜欢列表的内容」真的变了时自增。
    // 单独一个计数器是因为探测元数据也会频繁 revision++，若挂在一起，
    // 导入 100 首会重建 100 次喜欢列表（O(N²)），还会把列表滚动位置重置掉
    property int likedRevision: 0

    readonly property int count: songsModel.count
    readonly property var model: songsModel
    // 「我喜欢的音乐」，内容与主列表保持一致
    readonly property var likedSongs: likedModel

    // 结构变化（增 / 删）后发出，外部据此重新同步当前索引
    signal songsChanged()

    // 喜欢列表的内容一变就重建，保证两个视图的顺序一致
    onLikedRevisionChanged: store.syncLikedModel()

    // ---------- 持久化 ----------
    // 播放列表单独存成 playlist.json，**位置随平台**（见 main.cpp 的 configDirPath）：
    //   桌面 → ~/.musicplayer/　　安卓 → 应用私有目录 files/settings/musicplayer/
    // （安卓那份属沙箱，卸载应用时被系统一并删除）
    // 读写走 C++ 的 PlaylistFile —— QML 能读文件但写不了
    // 零散偏好（播放模式 / 输出设备）仍在 config.ini

    Timer {
        id: saveTimer
        interval: 400
        onTriggered: store.save()
    }

    ListModel {
        id: songsModel
    }

    // 喜欢列表：由 syncLikedModel() 依据 songsModel 中 liked 的项重建
    ListModel {
        id: likedModel
    }

    // ---------- 元数据探测 ----------
    // 独立于播放引擎，静默读取时长与标签，不发声
    // 队列按「文件」而不是「行号」记录：歌曲被删除后行号会整体前移，
    // 按行号探测会把 A 的标签写到 B 头上（删除歌曲后歌名/时长错乱就是这个原因）
    property var probeQueue: []      // 待探测的 file 列表
    property int probeCursor: 0      // 下一个要探测的下标（不 shift，避免 O(N²) 搬移）
    property string probeFile: ""    // 当前正在探测的文件，空串表示空闲

    MediaPlayer {
        id: prober
        audioOutput: null

        onMediaStatusChanged: {
            if (store.probeFile === "") return
            if (mediaStatus === MediaPlayer.LoadedMedia || mediaStatus === MediaPlayer.BufferedMedia) {
                store.applyProbe()
            } else if (mediaStatus === MediaPlayer.InvalidMedia) {
                store.finishProbe()
            }
        }
    }

    // 探测看门狗：异常文件可能既不 Loaded 也不 Invalid，没有超时会把整个队列卡死
    Timer {
        id: probeWatchdog
        interval: 8000
        onTriggered: store.finishProbe()
    }

    // ---------- 工具函数 ----------
    // 后缀清单由 C++ 的 FolderScanner 提供（扫描用的就是它），QML 不再各写一份。
    // 原生侧在 main.cpp 里必然注入，所以这里不做存在性判断
    readonly property var audioExtensions: folderScanner.audioSuffixes()

    function isAudioFile(url) {
        var s = "" + url
        var dot = s.lastIndexOf(".")
        if (dot >= 0 && audioExtensions.indexOf(s.substring(dot + 1).toLowerCase()) >= 0) return true
        // SAF / MediaProvider 返回的地址常常没有扩展名，向系统要 MIME 类型判断
        if (s.indexOf("content:") === 0) {
            try {
                return ("" + folderScanner.mimeType(url)).indexOf("audio/") === 0
            } catch (e) {
                return false
            }
        }
        return false
    }

    // 由地址推断展示用的音频格式：有扩展名直接用；content:// 地址常常没有扩展名
    // （媒体库的文档 ID 形如 audio:4211），这时向系统查 MIME 再映射回来
    function audioFormat(url) {
        var s = "" + url
        var dot = s.lastIndexOf(".")
        if (dot >= 0) {
            var ext = s.substring(dot + 1).toLowerCase()
            if (audioExtensions.indexOf(ext) >= 0) return ext
        }
        if (s.indexOf("content:") === 0) {
            try {
                return store.formatFromMime("" + folderScanner.mimeType(url))
            } catch (e) {
                return ""
            }
        }
        return ""
    }

    // MIME → 扩展名（与 FormatIcon 的配色表对齐）
    function formatFromMime(mime) {
        var m = ("" + mime).toLowerCase()
        if (m === "") return ""
        if (m.indexOf("audio/mpeg") === 0 || m.indexOf("mp3") >= 0) return "mp3"
        if (m.indexOf("flac") >= 0) return "flac"
        if (m.indexOf("wav") >= 0) return "wav"
        if (m.indexOf("m4a") >= 0) return "m4a"
        if (m.indexOf("mp4") >= 0) return "m4a"
        if (m.indexOf("aac") >= 0) return "aac"
        if (m.indexOf("ogg") >= 0) return "ogg"
        if (m.indexOf("opus") >= 0) return "opus"
        if (m.indexOf("wma") >= 0) return "wma"
        if (m.indexOf("ape") >= 0) return "ape"
        return ""
    }

    // 从纯名字（文件名 / 显示名）里解析「歌手 - 歌名」；解析不到就整体当歌名
    function parseName(raw) {
        var s = "" + raw
        // 先解码再截取：content:// 文档地址的真实分隔符是编码的 %2F，
        // 不解码会把 primary:Download 这类目录段混进歌名
        try {
            s = decodeURIComponent(s)
        } catch (e) {
        }
        var slash = Math.max(s.lastIndexOf("/"), s.lastIndexOf("\\"))
        var name = slash >= 0 ? s.substring(slash + 1) : s
        var dot = name.lastIndexOf(".")
        if (dot > 0) name = name.substring(0, dot)
        // SAF 文档地址经常只剩文档 ID（纯数字 / audio:1234 / primary:xxx 残留），不能当歌名
        if (looksLikeDocId(name))
            return { artist: "未知歌手", title: "未知歌曲" }
        var parts = name.split(" - ")
        if (parts.length >= 2 && parts[0].trim() !== "") {
            return { artist: parts[0].trim(), title: parts.slice(1).join(" - ").trim() }
        }
        return { artist: "未知歌手", title: name.trim() }
    }

    // content:// 地址本身常常只有文档 ID（形如 audio:1234），先向系统要显示名再解析
    function parseFileName(fileUrl) {
        var url = "" + fileUrl
        if (url.indexOf("content:") === 0) {
            var display = systemDisplayName(url)
            if (display !== "") {
                var byDisplay = parseName(display)
                if (byDisplay.title !== "未知歌曲")
                    return byDisplay
            }
        }
        return parseName(url)
    }

    // 向系统查 content:// 地址的真实显示名（Android）；失败返回空串
    function systemDisplayName(url) {
        try {
            return "" + folderScanner.displayName(url)
        } catch (e) {
            return ""
        }
    }

    // 是否是「文档 ID 式」的名字：纯数字、空串，或带 provider 前缀的文档 ID
    function looksLikeDocId(name) {
        if (!name) return true
        var s = ("" + name).trim()
        if (s === "") return true
        if (/^[0-9]+$/.test(s)) return true
        // MediaProvider / DocumentsProvider：audio:1234、image:99、msf:123、primary:xxx 等
        if (/^(audio|video|image|document|documents|download|downloads|media|file|raw|msf|primary)\s*:/i.test(s))
            return true
        return false
    }

    // 列表里的时长显示（未知显示 --:--；播放器那套显示 0:00）
    function formatMs(ms) {
        return Format.formatMs(ms, "--:--")
    }

    function pick(primary, fallback) {
        return (primary !== undefined && primary !== null && ("" + primary).trim() !== "")
                ? ("" + primary).trim() : fallback
    }

    // Qt 6 的 QMediaMetaData 在 QML 侧只有方法、没有 title 之类的属性，
    // 必须按 Key 取值（直接写 meta.title 永远是 undefined，标签会被静默丢弃）
    function readTags(meta) {
        var tags = { title: "", artist: "", album: "" }
        if (!meta) return tags
        try {
            tags.title = pick(meta.stringValue(MediaMetaData.Title), "")
            var albumArtist = pick(meta.stringValue(MediaMetaData.AlbumArtist), "")
            var contributing = pick(meta.stringValue(MediaMetaData.ContributingArtist), "")
            tags.artist = albumArtist !== "" ? albumArtist : contributing
            tags.album = pick(meta.stringValue(MediaMetaData.AlbumTitle), "")
        } catch (e) {
            // 个别平台后端可能不暴露完整 Key，读不到就退回文件名解析
        }
        return tags
    }

    // ---------- 读取 ----------
    function songAt(index) {
        if (index < 0 || index >= songsModel.count) return null
        return songsModel.get(index)
    }

    function indexOfFile(fileUrl) {
        if (!fileUrl) return -1
        for (var i = 0; i < songsModel.count; ++i) {
            if (songsModel.get(i).file === fileUrl) return i
        }
        return -1
    }

    // 全部歌曲的 file 序列，供播放队列使用
    function allFiles() {
        var arr = []
        for (var i = 0; i < songsModel.count; ++i) arr.push(songsModel.get(i).file)
        return arr
    }

    // 喜欢歌曲的 file 序列，供播放队列使用
    function likedFiles() {
        var arr = []
        for (var i = 0; i < likedModel.count; ++i) arr.push(likedModel.get(i).file)
        return arr
    }

    // 依据主列表重建喜欢列表
    function syncLikedModel() {
        likedModel.clear()
        for (var i = 0; i < songsModel.count; ++i) {
            var r = songsModel.get(i)
            if (!r.liked) continue
            likedModel.append({
                file: r.file,
                title: r.title,
                artist: r.artist,
                format: r.format,
                durationText: r.durationText,
                liked: true
            })
        }
    }

    // ---------- 增删改 ----------
    // 批量导入：trusted = true 时跳过后缀校验（文件夹扫描已按 MIME 过滤、
    // 单选文件选择器已限定音频类型，SAF 返回的地址可能不带扩展名）
    function addFiles(urls, trusted) {
        var report = { added: 0, duplicate: 0, invalid: 0, failed: 0 }
        if (!urls || urls.length === 0) return report
        // 先用快照建索引：逐首线性查重会把批量导入拖成 O(N²)，文件一多就卡
        var existing = {}
        for (var j = 0; j < songsModel.count; ++j)
            existing[songsModel.get(j).file] = true

        var added = []
        for (var i = 0; i < urls.length; ++i) {
            var url = "" + urls[i]
            if (url === "") continue
            if (existing[url]) {
                report.duplicate++
                console.warn("[addFiles] 已在曲库，跳过:", url)
                continue
            }
            if (!trusted && !isAudioFile(url)) {
                report.invalid++
                console.warn("[addFiles] 非音频，跳过:", url)
                continue
            }
            try {
                var parsed = parseFileName(url)
                songsModel.append({
                    file: url,
                    title: parsed.title,
                    artist: parsed.artist,
                    album: "",
                    format: store.audioFormat(url),
                    durationMs: 0,
                    durationText: "--:--",
                    liked: false,
                    probed: false
                })
                existing[url] = true
                added.push(url)
                report.added++
            } catch (e) {
                // 单条坏数据不应带崩整批导入
                report.failed++
            }
        }
        if (added.length === 0) {
            console.warn("[addFiles] 无新增 | 总数", urls.length,
                         "重复", report.duplicate, "非音频", report.invalid, "失败", report.failed,
                         "| 当前曲库", songsModel.count)
            return report
        }
        // 注意：songsModel 已在上面 append 完毕，count 就是加入后的总数，
        // 不能再加 added.length（会把新增数算两遍）
        console.warn("[addFiles] 新增", report.added,
                     "重复", report.duplicate, "非音频", report.invalid, "失败", report.failed,
                     "| 曲库共", songsModel.count)
        store.revision++
        store.songsChanged()
        store.enqueueProbe(added)
        // 结构变化立即落盘：删除/新增后若只等防抖保存，进程被kill就会丢状态
        store.save()
        return report
    }

    // 系统「打开方式」进来的文件：content:// 地址常常没有扩展名，跳过后缀校验直接收录
    // 已在歌单里就返回原下标，便于上层直接播放
    function addExternalFile(url) {
        if (!url) return -1
        var exist = indexOfFile(url)
        if (exist >= 0) return exist
        var parsed = parseFileName(url)
        songsModel.append({
            file: url,
            title: parsed.title,
            artist: parsed.artist,
            album: "",
            format: store.audioFormat(url),
            durationMs: 0,
            durationText: "--:--",
            liked: false,
            probed: false
        })
        var index = songsModel.count - 1
        store.revision++
        store.songsChanged()
        store.enqueueProbe([url])
        store.save()
        return index
    }

    // 从曲库「移出」若干文件（只在列表层面移除，绝不碰磁盘上的文件）。
    // 用于播放列表在「全部」视图下的删除。返回实际移出的数量
    function removeFiles(files) {
        if (!files || files.length === 0) return 0
        var removed = 0
        for (var k = 0; k < files.length; ++k) {
            var index = indexOfFile(files[k])
            if (index < 0) continue
            songsModel.remove(index)
            removed++
        }
        if (removed === 0) return 0
        console.warn("[removeFiles] 从曲库移出", removed, "首 | 曲库剩", songsModel.count, "首")
        store.revision++
        store.likedRevision++          // 被删的可能是喜欢的歌
        store.songsChanged()
        // 立即落盘，保证「删除 → 再添加」闭环不依赖防抖计时器
        store.save()
        return removed
    }

    // 取消若干首歌的喜欢标记；曲目仍保留在「全部」列表。
    // 用于播放列表在「我喜欢」视图下的删除。返回实际取消的数量
    function unlikeFiles(files) {
        if (!files || files.length === 0) return 0
        var changed = 0
        for (var k = 0; k < files.length; ++k) {
            var index = indexOfFile(files[k])
            if (index < 0) continue
            if (!songsModel.get(index).liked) continue
            songsModel.setProperty(index, "liked", false)
            changed++
        }
        if (changed === 0) return 0
        console.warn("[unlikeFiles] 取消喜欢", changed, "首")
        // revision 供各处绑定刷新；likedRevision 触发喜欢列表重建
        store.revision++
        store.likedRevision++
        store.save()
        return changed
    }

    // 移除指定文件（用于清理已失效的曲目），返回是否真的删掉了
    function removeFile(fileUrl) {
        var index = indexOfFile(fileUrl)
        if (index < 0) return false
        songsModel.remove(index)
        console.warn("[removeFile] 移除失效曲目:", fileUrl, "| 曲库剩", songsModel.count, "首")
        store.revision++
        store.likedRevision++          // 被删的可能是喜欢的歌
        store.songsChanged()
        // 与批量移出同样立即落盘，避免下次启动又把失效曲目读回来
        store.save()
        return true
    }

    function toggleLiked(index) {
        if (index < 0 || index >= songsModel.count) return
        songsModel.setProperty(index, "liked", !songsModel.get(index).liked)
        store.revision++
        store.likedRevision++
        store.scheduleSave()
    }

    // ---------- 元数据探测流程 ----------
    // 批量导入 5000 首曾要 5.7 秒、10000 首要 32 秒。根因是这里两处 O(N²)：
    //   ① 队列查重用 indexOf（每加一首都全表扫一遍）
    //   ② probeNext 用 slice()+shift() 取队首（每探测一首都搬移整个数组）
    // 现在改成「哈希查重 + 游标推进」，两个循环都是 O(N)。
    function enqueueProbe(files) {
        if (!files || files.length === 0) return
        var seen = {}
        for (var i = probeCursor; i < probeQueue.length; ++i)
            seen["" + probeQueue[i]] = true
        for (var j = 0; j < files.length; ++j) {
            var f = "" + files[j]
            if (f === "" || seen[f]) continue
            seen[f] = true
            probeQueue.push(f)
        }
        if (probeFile === "") probeNext()
    }

    function probeNext() {
        // 用 while 跳过已删除的条目：递归写法在「整批都被删掉」时会爆栈
        while (probeCursor < probeQueue.length) {
            var next = probeQueue[probeCursor++]
            if (indexOfFile(next) < 0)
                continue
            probeFile = next
            prober.source = next
            probeWatchdog.restart()
            return
        }
        probeFile = ""
        prober.source = ""
        probeWatchdog.stop()
        probeQueue = []
        probeCursor = 0
    }

    function applyProbe() {
        var file = probeFile
        var index = indexOfFile(file)
        if (index < 0) {
            probeNext()
            return
        }
        var tags = readTags(prober.metaData)
        var parsed = parseFileName(file)
        var title = pick(tags.title, parsed.title)
        // 标签里也可能混进文档 ID 之类的脏数据，清洗后回退文件名解析
        if (looksLikeDocId(title)) title = parsed.title
        var artist = pick(tags.artist, parsed.artist)
        var album = tags.album
        songsModel.setProperty(index, "title", title)
        songsModel.setProperty(index, "artist", artist)
        songsModel.setProperty(index, "album", album)
        songsModel.setProperty(index, "durationMs", prober.duration > 0 ? prober.duration : 0)
        songsModel.setProperty(index, "durationText", formatMs(prober.duration))
        songsModel.setProperty(index, "probed", true)
        store.revision++
        // 喜欢列表是主列表的副本：这首歌在里面时，元数据变了要跟着重建
        if (songsModel.get(index).liked) store.likedRevision++
        store.scheduleSave()
        probeNext()
    }

    // 探测失败 / 超时：标记为已探测（时长未知），继续队列里下一首
    function finishProbe() {
        var file = probeFile
        if (file !== "") {
            var index = indexOfFile(file)
            if (index >= 0 && !songsModel.get(index).probed) {
                songsModel.setProperty(index, "durationText", "--:--")
                songsModel.setProperty(index, "probed", true)
                store.revision++
            }
        }
        store.scheduleSave()
        probeNext()
    }

    // ---------- 存取 ----------
    function scheduleSave() {
        saveTimer.restart()
    }

    function save() {
        saveTimer.stop()
        var arr = []
        for (var i = 0; i < songsModel.count; ++i) {
            var r = songsModel.get(i)
            arr.push({
                file: r.file,
                title: r.title,
                artist: r.artist,
                album: r.album,
                format: r.format,
                durationMs: r.durationMs,
                durationText: r.durationText,
                liked: r.liked,
                probed: r.probed
            })
        }
        playlistFile.write(JSON.stringify(arr))
    }

    function load() {
        var arr = []
        try {
            // 文件不存在时 read() 返回空串，JSON.parse 会抛异常，按空列表处理
            arr = JSON.parse(playlistFile.read())
        } catch (e) {
            arr = []
        }
        if (!Array.isArray(arr)) arr = []

        songsModel.clear()
        for (var i = 0; i < arr.length; ++i) {
            var s = arr[i]
            if (!s || !s.file) continue
            var parsed = parseFileName(s.file)
            var title = s.title || parsed.title
            // 旧版本可能把文档 ID / 脏前缀存进了歌名，重新按文件名解析
            if (looksLikeDocId(title))
                title = parsed.title
            songsModel.append({
                file: s.file,
                title: title,
                artist: s.artist || "未知歌手",
                album: s.album || "",
                // 旧数据没有这个字段，按地址重新推一次
                format: s.format || store.audioFormat(s.file),
                durationMs: s.durationMs || 0,
                durationText: s.durationText || "--:--",
                liked: s.liked === true,
                probed: s.probed === true
            })
        }
        store.revision++
        store.likedRevision++          // 整表重建，喜欢列表也要跟着初始化
        store.songsChanged()

        // 上次没探到元数据的，本次启动重试一遍
        var retry = []
        for (var j = 0; j < songsModel.count; ++j) {
            if (songsModel.get(j).durationMs === 0) retry.push(songsModel.get(j).file)
        }
        store.enqueueProbe(retry)
    }
}
