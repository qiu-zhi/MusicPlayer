import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

// 播放列表面板：底部上滑停靠的 Bottom Sheet，高度约为视口 55%
Item {
    id: playlistPanel

    property var allSongs: null       // 全部歌曲 ListModel
    property var likedSongs: null     // 我喜欢的 ListModel
    property string currentFile: ""   // 正在播放的歌曲文件，用于高亮
    property bool showLiked: false    // 当前视图：false 全部 / true 我喜欢的

    // 下拉拖动位移：0 = 停靠位置；Main 侧据此把面板整体往下带，
    // 松手后按拖动距离决定收起或回弹
    property real dragOffset: 0
    property bool dragging: false

    // 松手回弹用缓动；拖动跟手期间不插值
    Behavior on dragOffset {
        enabled: !playlistPanel.dragging
        NumberAnimation { duration: 250; easing.type: Easing.OutCubic }
    }

    signal itemClicked(string file, bool likedView)
    signal manageRequested()
    signal closeRequested()

    readonly property string iconBase: "../assets/icons/"
    readonly property int allCount: allSongs ? allSongs.count : 0
    readonly property int likedCount: likedSongs ? likedSongs.count : 0
    readonly property int activeCount: showLiked ? likedCount : allCount
    readonly property var activeSongs: showLiked ? likedSongs : allSongs

    // 左滑返回：喜欢视图先回到全部视图，全部视图直接收起面板
    // 横竖手势分工：横滑走这里，竖滑仍归列表滚动，互不抢占
    // 注意：PointerHandler 不是 Item，没有 anchors —— 它默认就作用于所属 Item 的范围
    DragHandler {
        xAxis.enabled: true
        yAxis.enabled: false
        dragThreshold: 24

        property bool fired: false

        onActiveChanged: if (!active) fired = false
        onTranslationChanged: {
            if (!fired && translation.x < -70) {
                fired = true
                if (playlistPanel.showLiked) playlistPanel.showLiked = false
                else playlistPanel.closeRequested()
            }
        }
    }

    // 面板背景：顶部圆角，底部两角贴屏幕边缘
    Rectangle {
        id: sheetBg
        anchors.fill: parent
        color: "#FFFFFF"
        radius: 16
        border.color: "#E1E3E7"
        border.width: 1

        // 盖住底部圆角，让面板底边与屏幕底边齐平
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.radius
            color: parent.color
        }
    }

    // 把手
    Rectangle {
        id: handle
        anchors.top: parent.top
        anchors.topMargin: 8
        anchors.horizontalCenter: parent.horizontalCenter
        width: 40
        height: 4
        radius: 2
        color: "#D8DADD"
    }

    // 头部：标题 + 操作
    Item {
        id: header
        width: parent.width - 24
        height: 44
        anchors.top: handle.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.leftMargin: 12

        Text {
            text: playlistPanel.showLiked
                  ? "我喜欢的音乐 (" + playlistPanel.likedCount + ")"
                  : "播放列表 (" + playlistPanel.allCount + ")"
            color: "#17181A"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }

        Row {
            id: actionRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            IconButton {
                iconSource: playlistPanel.iconBase + "pencil.svg"
                iconColor: "#8A8D92"
                iconSize: 17
                implicitWidth: 32
                implicitHeight: 32
                tooltipText: "管理音乐库"
                onClicked: playlistPanel.manageRequested()
            }

            IconButton {
                iconSource: playlistPanel.iconBase + "x.svg"
                iconColor: "#8A8D92"
                iconSize: 18
                implicitWidth: 32
                implicitHeight: 32
                tooltipText: "关闭"
                onClicked: playlistPanel.closeRequested()
            }
        }
    }

    // 全部 / 我喜欢的 分段切换
    Rectangle {
        id: viewSwitch
        height: 32
        anchors.top: header.bottom
        anchors.topMargin: 6
        anchors.left: header.left
        anchors.right: header.right
        radius: 9
        color: "#F0F1F3"

        // 选中滑块：只让它滑动，避免两个分段同时变色造成闪烁
        Rectangle {
            id: thumb
            width: (viewSwitch.width - 9) / 2
            height: viewSwitch.height - 6
            y: 3
            x: 3 + (playlistPanel.showLiked ? width + 3 : 0)
            radius: 7
            color: "#FFFFFF"
            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }

        Row {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 3

            Repeater {
                model: [
                    { label: "全部", liked: false },
                    { label: "我喜欢的", liked: true }
                ]

                delegate: Item {
                    id: segItem
                    readonly property bool selected: playlistPanel.showLiked === modelData.liked

                    width: (viewSwitch.width - 9) / 2
                    height: parent.height

                    Text {
                        anchors.centerIn: parent
                        text: modelData.label
                        color: segItem.selected ? "#F3693A" : "#8A8D92"
                        font.pixelSize: 12
                        font.weight: segItem.selected ? Font.DemiBold : Font.Normal
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: playlistPanel.showLiked = modelData.liked
                    }
                }
            }
        }
    }

    // 列表
    ListView {
        id: listView
        anchors.top: viewSwitch.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 6
        anchors.bottomMargin: 12 + playlistPanel.SafeArea.margins.bottom
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        clip: true
        spacing: 2
        visible: playlistPanel.activeCount > 0
        boundsBehavior: Flickable.DragOverBounds

        model: playlistPanel.activeSongs

        delegate: Rectangle {
            id: rowItem
            required property int index
            required property string file
            required property string title
            required property string artist
            required property string durationText
            required property string format
            required property bool liked

            readonly property bool current: file === playlistPanel.currentFile

            width: listView.width
            height: 50
            radius: 8
            color: rowItem.current ? "#1AF3693A"
                 : rowMouse.containsMouse ? "#0A000000"
                 : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10

                // 文件类型图标：统一音符造型，按格式着色
                FormatIcon {
                    file: rowItem.file
                    format: rowItem.format
                    size: 30
                    Layout.alignment: Qt.AlignVCenter
                }

                // 歌名和歌手
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                        text: rowItem.title
                        color: rowItem.current ? "#17181A" : "#4A4E54"
                        font.pixelSize: 13
                        Layout.fillWidth: true
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }
                    Text {
                        text: rowItem.artist
                        color: "#8A8D92"
                        font.pixelSize: 11
                        Layout.fillWidth: true
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }
                }

                // 「全部」视图里给已喜欢的行标一个心形
                Item {
                    Layout.preferredWidth: 14
                    Layout.preferredHeight: 14
                    visible: !playlistPanel.showLiked && rowItem.liked

                    Image {
                        id: likedMark
                        anchors.fill: parent
                        source: playlistPanel.iconBase + "heart-filled.svg"
                        sourceSize: Qt.size(14, 14)
                        visible: false
                    }
                    ColorOverlay {
                        anchors.fill: likedMark
                        source: likedMark
                        color: "#F3693A"
                    }
                }

                // 时长
                Text {
                    text: rowItem.durationText
                    color: "#B9BDC2"
                    font.pixelSize: 11
                    Layout.alignment: Qt.AlignVCenter
                }
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: playlistPanel.itemClicked(rowItem.file, playlistPanel.showLiked)
            }
        }

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AlwaysOff
        }
    }

    // 空状态
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: playlistPanel.activeCount === 0

        Text {
            text: playlistPanel.showLiked ? "还没有喜欢的歌曲" : "播放列表还是空的"
            color: "#8A8D92"
            font.pixelSize: 13
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            visible: playlistPanel.showLiked
            text: "在播放页点歌名左侧的心形即可收藏"
            color: "#B9BDC2"
            font.pixelSize: 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        IconButton {
            visible: !playlistPanel.showLiked
            iconSource: playlistPanel.iconBase + "plus.svg"
            iconColor: "#F3693A"
            iconSize: 20
            implicitWidth: 44
            implicitHeight: 44
            tooltipText: "去添加音乐"
            anchors.horizontalCenter: parent.horizontalCenter
            onClicked: playlistPanel.manageRequested()
        }
    }

    // 顶部把手拖动区：下拉收起面板（右侧让给操作按钮，避开误触）
    MouseArea {
        id: handleArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.rightMargin: 120
        height: handle.y + handle.height + 30
        drag.axis: Drag.YAxis

        property real pressY: 0

        onPressed: function(mouse) {
            pressY = mouse.y
            playlistPanel.dragging = true
        }

        onPositionChanged: function(mouse) {
            if (!pressed) return
            var dy = mouse.y - pressY
            playlistPanel.dragOffset = dy > 0 ? Math.min(dy, playlistPanel.height) : 0
        }

        onReleased: {
            // 拖动超过 90px 判定为收起：拖动量归零（回弹动画）与收起动画并行，
            // 面板从当前拖动态平滑滑到完全隐藏；否则只是缓动弹回停靠位
            var shouldClose = playlistPanel.dragOffset > 90
            playlistPanel.dragging = false
            playlistPanel.dragOffset = 0
            if (shouldClose) playlistPanel.closeRequested()
        }

        onCanceled: {
            playlistPanel.dragging = false
            playlistPanel.dragOffset = 0
        }
    }
}
