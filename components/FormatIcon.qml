import QtQuick
import Qt5Compat.GraphicalEffects

// 播放列表的文件图标：统一音符造型 + 按音频格式着色的圆角底衬
// 后续要按格式换图标，只改 source 即可，底衬与尺寸不用动
Item {
    id: formatIcon

    property string file: ""
    // 数据层解析好的格式（如 mp3 / flac）。content:// 地址常常没有扩展名，
    // 只靠地址推导会全部落到默认灰，所以优先用这个字段
    property string format: ""
    property int size: 30
    readonly property string iconBase: "../assets/icons/"

    readonly property string ext: {
        if (formatIcon.format !== "") return ("" + formatIcon.format).toLowerCase()
        var s = "" + formatIcon.file
        var dot = s.lastIndexOf(".")
        return dot >= 0 ? s.substring(dot + 1).toLowerCase() : ""
    }

    // 按格式区分颜色、造型保持统一：MP3 橙 / FLAC 蓝 / WAV 绿 / M4A·AAC 紫 / 其他灰
    readonly property color tint: {
        switch (formatIcon.ext) {
        case "mp3": return "#F3693A"
        case "flac": return "#4A90D9"
        case "wav": return "#3FA46A"
        case "m4a":
        case "aac": return "#9B59D0"
        case "ogg":
        case "opus": return "#E67E22"
        case "wma": return "#5B7DB1"
        case "ape": return "#C0603A"
        default: return "#8A8D92"
        }
    }

    implicitWidth: size
    implicitHeight: size

    Rectangle {
        anchors.fill: parent
        radius: Math.round(formatIcon.size * 0.3)
        color: "#FFFFFF"
        border.color: "#E4E6E9"
        border.width: 1
    }

    Item {
        width: Math.round(formatIcon.size * 0.58)
        height: Math.round(formatIcon.size * 0.58)
        anchors.centerIn: parent

        Image {
            id: noteIcon
            anchors.fill: parent
            source: formatIcon.iconBase + "music-note.svg"
            sourceSize: Qt.size(parent.width, parent.height)
            fillMode: Image.PreserveAspectFit
        }

        ColorOverlay {
            anchors.fill: noteIcon
            source: noteIcon
            color: formatIcon.tint
        }
    }
}
