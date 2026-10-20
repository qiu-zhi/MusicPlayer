import QtQuick

// 歌词页：歌名 / 歌手 + 可点击跳转的歌词列表
Item {
    id: page

    property string title: ""
    property string subtitle: ""
    property var lyrics: null
    property int currentIndex: -1

    // 点了某一行歌词，交出该行的时间戳（要不要跳由上层判断）
    signal seekRequested(int timeMs)

    Column {
        id: songInfo
        width: parent.width - 32
        anchors.top: parent.top
        anchors.topMargin: 76      // 让开顶部返回按钮
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: 2

        Text {
            text: page.title
            color: Theme.ink
            font.pixelSize: 16
            font.bold: true
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: page.subtitle
            color: Theme.muted
            font.pixelSize: 12
            anchors.horizontalCenter: parent.horizontalCenter
        }
    }

    LyricsView {
        id: list
        anchors.top: songInfo.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 16
        lyrics: page.lyrics
        currentIndex: page.currentIndex

        onLineClicked: function(index) {
            var line = page.lyrics ? page.lyrics[index] : null
            if (line) page.seekRequested(line.timeMs)
        }
    }
}
