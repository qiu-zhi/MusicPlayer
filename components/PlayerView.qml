import QtQuick

// 播放视图：唱机 + 歌曲信息 + 当前歌词行 + 空歌单入口
// 纯展示组件，所有数据由外部属性注入，交互通过信号回传
Item {
    id: playerView

    // ---- 数据输入 ----
    property bool playing: false          // 唱机是否转动
    property string iconBase: ""          // 图标路径前缀
    property string title: ""             // 歌名
    property string subtitle: ""          // 歌手 · 专辑
    property string lyricText: ""         // 正在唱的那句歌词
    property bool hasSongs: false         // 是否有歌曲（控制收藏按钮与空态入口）
    property bool liked: false            // 当前曲目是否已收藏

    // ---- 交互输出 ----
    signal likeToggled()                  // 点击收藏按钮
    signal lyricClicked()                 // 点击歌词行（进入歌词页）
    signal addMusicRequested()            // 点击空态「去添加音乐」

    // 唱机领衔：唱机放大居中，歌曲信息下移到唱机下方
    Column {
        id: playerContent
        width: parent.width - 48
        anchors.centerIn: parent
        spacing: 20

        Turntable {
            id: turntable
            // 限制最大宽度：窗口被放大/最大化时唱机不会跟着无限变大
            width: Math.min(parent.width, 300)
            x: (parent.width - width) / 2
            playing: playerView.playing
            coverSource: ""
        }

        Column {
            width: parent.width
            spacing: 6

            // 歌名 + 左侧收藏按钮
            Item {
                width: parent.width
                height: Math.max(titleText.implicitHeight, 32)

                Text {
                    id: titleText
                    text: playerView.title
                    color: "#17181A"
                    font.pixelSize: 22
                    font.bold: true
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(implicitWidth, parent.width - 44)
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }

                IconButton {
                    anchors.right: titleText.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: titleText.verticalCenter
                    visible: playerView.hasSongs
                    iconSource: playerView.liked ? playerView.iconBase + "heart-filled.svg"
                                                 : playerView.iconBase + "heart.svg"
                    iconColor: playerView.liked ? "#F3693A" : "#8A8D92"
                    iconSize: 18
                    implicitWidth: 32
                    implicitHeight: 32
                    tooltipText: playerView.liked ? "取消喜欢" : "喜欢"
                    onClicked: playerView.likeToggled()
                }
            }

            Text {
                text: playerView.subtitle
                color: "#8A8D92"
                font.pixelSize: 13
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                maximumLineCount: 1
                elide: Text.ElideMiddle
            }
        }

        // 正在唱的那句歌词，点击进入歌词页
        Item {
            width: parent.width
            height: 22

            Text {
                id: lyricLine
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width)
                text: playerView.lyricText
                color: lyricHit.containsMouse ? "#F3693A" : "#17181A"
                font.pixelSize: 15
                maximumLineCount: 1
                elide: Text.ElideRight
                Behavior on color { ColorAnimation { duration: 120 } }
            }

            MouseArea {
                id: lyricHit
                anchors.fill: lyricLine
                hoverEnabled: true
                enabled: playerView.lyricText !== ""
                cursorShape: Qt.PointingHandCursor
                onClicked: playerView.lyricClicked()
            }
        }

        // 空歌单时给一个明确的入口
        Item {
            width: parent.width
            height: addFirstSong.height
            visible: !playerView.hasSongs

            PillButton {
                id: addFirstSong
                anchors.horizontalCenter: parent.horizontalCenter
                iconSource: playerView.iconBase + "plus.svg"
                text: "去添加音乐"
                textColor: "#FFFFFF"
                iconColor: "#FFFFFF"
                bgColor: "#F3693A"
                borderColor: "#F3693A"
                onClicked: playerView.addMusicRequested()
            }
        }
    }
}
