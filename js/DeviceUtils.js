.pragma library

// 输出设备名的显示处理。纯字符串逻辑，跟播放链路无关。

// 是否是蓝牙描述（按描述 / id 判断）
function isBluetoothDescription(desc) {
    var t = ("" + desc).toLowerCase()
    return t.indexOf("bluetooth") >= 0 || t.indexOf("a2dp") >= 0
}

// 把系统设备名翻成用户一眼能看懂的短名：
// 先按关键字归类（显示器 / 耳机 / 扬声器 / 蓝牙），再取括号里最前面的具体型号。
// 归类失败就原样返回，不猜。
//   例：VX2478-2 (HD Audio Driver for Display Audio) → 显示器 (VX2478-2)
function friendlyDeviceName(raw) {
    var desc = "" + raw
    var lower = desc.toLowerCase()

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

    // head 里已经有类别词（Bluetooth / Headphone / Speaker）就剥掉，
    // 剥完还有内容（型号）就用它标注，否则退回类别名
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

    // head 没信息量：用括号里的芯片/厂商名兜底
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
