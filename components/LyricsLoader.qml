import QtQuick

// LRC 歌词加载与解析：找音频同名的 .lrc 文件，解析时间轴供歌词视图使用
Item {
    id: lyricLoader
    width: 0
    height: 0

    property string source: ""   // 当前音频文件 URL
    property var lines: []       // [{ timeMs, text }]，按时间升序
    property bool loaded: false
    property string loadedFrom: ""   // 已成功加载过的 source，防止重复加载

    onSourceChanged: load()

    // 由音频路径推导歌词路径：同名 .lrc
    function lrcUrl(audioUrl) {
        if (!audioUrl) return ""
        var s = "" + audioUrl
        var query = s.indexOf("?")
        var base = query >= 0 ? s.substring(0, query) : s
        var dot = base.lastIndexOf(".")
        if (dot < 0) return ""
        return base.substring(0, dot) + ".lrc"
    }

    function load() {
        // 同一个源不重复加载：重复触发会让 lines/loaded 反复在 [] / false 与有效值之间跳，
        // displayLyrics 与 currentLyricIndex 随之抖动 → 歌词界面"闪"
        if (source === loadedFrom) return
        lines = []
        loaded = false
        loadedFrom = ""
        if (source === "") return

        // 优先走原生侧：Android 上音频是 content:// 地址（媒体库的文档 ID 里
        // 连扩展名都没有），既拼不出同名 .lrc 的地址，XHR 也读不了 content scheme。
        // 原生侧会沿 DocumentsContract 在同目录里找同名 .lrc 并读回文本
        var text = ""
        if (typeof folderScanner !== "undefined") {
            try {
                text = "" + folderScanner.readLyrics(source)
            } catch (e) {
                text = ""
            }
        }
        if (text !== "") {
            applyText(text)
            return
        }

        // 兜底：按「同名 .lrc」拼地址后用 XHR 取（本地路径场景）
        var url = lrcUrl(source)
        if (url === "") return

        var xhr = new XMLHttpRequest()
        xhr.open("GET", url)
        try {
            xhr.overrideMimeType("text/plain; charset=utf-8")
        } catch (e) {
        }
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var body = ""
            try {
                body = xhr.responseText || ""
            } catch (e) {
                body = ""
            }
            if (body.length === 0) return
            lyricLoader.applyText(body)
        }
        try {
            xhr.send()
        } catch (e) {
        }
    }

    function applyText(text) {
        var parsed = parse(text)
        lines = parsed
        loaded = parsed.length > 0
        // 只有真正解析出内容才标记"已加载"，避免空歌词被反复重试
        if (loaded) loadedFrom = source
    }

    // 解析标准 LRC：支持一行多时间戳、[offset:] 补偿
    function parse(text) {
        var out = []
        var offset = 0
        var timeTag = /\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]/g
        var raw = ("" + text).split(/\r?\n/)

        for (var i = 0; i < raw.length; ++i) {
            var line = raw[i]
            if (line === undefined || line === null || line === "") continue

            var offsetMatch = line.match(/^\s*\[offset:\s*([+-]?\d+)\s*\]\s*$/i)
            if (offsetMatch) {
                offset = parseInt(offsetMatch[1], 10) || 0
                continue
            }

            timeTag.lastIndex = 0
            var stamps = []
            var match
            while ((match = timeTag.exec(line)) !== null) {
                var minutes = parseInt(match[1], 10) || 0
                var seconds = parseInt(match[2], 10) || 0
                var fraction = 0
                if (match[3] !== undefined) {
                    var frac = match[3]
                    if (frac.length === 1) fraction = parseInt(frac, 10) * 100
                    else if (frac.length === 2) fraction = parseInt(frac, 10) * 10
                    else fraction = parseInt(frac, 10)
                }
                stamps.push((minutes * 60 + seconds) * 1000 + fraction)
            }
            if (stamps.length === 0) continue

            var content = line.replace(timeTag, "").trim()
            for (var k = 0; k < stamps.length; ++k) {
                out.push({ timeMs: stamps[k], text: content })
            }
        }

        if (offset !== 0) {
            for (var j = 0; j < out.length; ++j) {
                out[j].timeMs += offset
            }
        }
        out.sort(function(a, b) { return a.timeMs - b.timeMs })
        return out
    }

    // 二分查找：返回最后一个时间 <= ms 的行号，找不到返回 -1
    function indexAt(ms) {
        if (!lines || lines.length === 0) return -1
        var lo = 0
        var hi = lines.length - 1
        var answer = -1
        while (lo <= hi) {
            var mid = (lo + hi) >> 1
            if (lines[mid].timeMs <= ms) {
                answer = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return answer
    }
}