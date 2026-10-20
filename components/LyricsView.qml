import QtQuick
import Qt5Compat.GraphicalEffects

Item {
    id: lyricsView
    clip: true

    property int currentIndex: 0
    property var lyrics: [] // [{ timeMs: 12000, text: "歌词内容" }, ...]

    signal lineClicked(int index)

    // 单行占位高度与行间距，滚动定位与布局共用
    readonly property real lineHeight: 40
    readonly property real lineSpacing: 6

    // 居中偏移（让当前行位于视图中央）
    readonly property real centerOffset: height / 2 - lineHeight / 2

    // 歌词列表
    ListView {
        id: lyricsList
        anchors.fill: parent
        anchors.topMargin: 40
        anchors.bottomMargin: 40
        spacing: lyricsView.lineSpacing
        model: lyricsView.lyrics
        clip: true
        interactive: true
        boundsBehavior: Flickable.DragOverBounds

        delegate: Item {
            width: lyricsList.width
            height: lyricsView.lineHeight

            Text {
                id: lineText
                text: modelData.text
                anchors.centerIn: parent
                font.pixelSize: index === lyricsView.currentIndex ? 20 : 15
                font.weight: index === lyricsView.currentIndex ? Font.DemiBold : Font.Normal
                color: index === lyricsView.currentIndex ? Theme.accent :
                       Math.abs(index - lyricsView.currentIndex) === 1 ? Theme.muted :
                       Theme.disabled
                maximumLineCount: 1
                elide: Text.ElideMiddle
                width: parent.width - 40
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.NoWrap

                Behavior on color { ColorAnimation { duration: 300 } }
                Behavior on font.pixelSize { NumberAnimation { duration: 200 } }
            }

            MouseArea {
                anchors.fill: parent
                onClicked: lyricsView.lineClicked(index)
            }
        }

        // 当前行居中滚动
        function scrollToCurrent() {
            if (lyricsView.currentIndex >= 0 && lyricsView.currentIndex < count) {
                var targetY = lyricsView.currentIndex * (lyricsView.lineHeight + lyricsView.lineSpacing) - lyricsView.centerOffset + 40
                // 首行 / 末行的时间贴近 0 或总时长时，目标位置会超出可滚动范围，
                // 直接赋值会越过边界；夹回边界，由 Flickable 自己贴齐边缘
                contentY = Math.max(0, Math.min(targetY, contentHeight - height))
            }
        }
    }

    // 上下渐隐遮罩
    LinearGradient {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 60
        gradient: Gradient {
            GradientStop { position: 0.0; color: Theme.bg }
            GradientStop { position: 1.0; color: "transparent" }
        }
        start: Qt.point(0, 0)
        end: Qt.point(0, height)
        z: 10
    }

    LinearGradient {
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: 60
        gradient: Gradient {
            GradientStop { position: 0.0; color: "transparent" }
            GradientStop { position: 1.0; color: Theme.bg }
        }
        start: Qt.point(0, 0)
        end: Qt.point(0, height)
        z: 10
    }

    // 当 currentIndex 变化时平滑滚动
    onCurrentIndexChanged: {
        lyricsList.scrollToCurrent()
    }
}
