.pragma library

// 毫秒 → "m:ss"。unknown 是「还没有时长」时的占位：
// 列表里用 "--:--"，播放器时间用 "0:00" —— 只有这一处实现
function formatMs(ms, unknown) {
    if (!ms || ms <= 0) return unknown === undefined ? "0:00" : unknown
    var total = Math.floor(ms / 1000)
    var m = Math.floor(total / 60)
    var s = total % 60
    return m + ":" + (s < 10 ? "0" + s : "" + s)
}
