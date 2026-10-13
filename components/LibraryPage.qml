import QtQuick
import QtQuick.Controls
import QtQuick.Dialogs
import Qt5Compat.GraphicalEffects

// 音乐库管理页：整页覆盖，支持添加文件 / 批量删除
Item {
    id: libraryPage

    property var store: null
    property int currentIndex: -1

    signal closeRequested()
    signal playRequested(int index)

    readonly property string iconBase: "../assets/icons/"
    readonly property color ink: "#17181A"
    readonly property color muted: "#8A8D92"
    readonly property color accent: "#F3693A"
    readonly property color surface: "#FFFFFF"
    readonly property color hairline: "#E4E6E9"

    readonly property int songCount: store ? store.count : 0
    readonly property int checkedCount: store ? store.checkedCount : 0
    readonly property bool allChecked: songCount > 0 && checkedCount === songCount
    readonly property bool hasSelection: checkedCount > 0

    function showHint(message) {
        pageToast.text = message
    }

    // 左滑返回：与列表的竖向滚动互不抢占（横滑归手势，竖滑归列表）
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
                libraryPage.closeRequested()
            }
        }
    }

    // ---------- 背景遮住下层页面，避免点击穿透 ----------
    Rectangle {
        anchors.fill: parent
        color: "#E3E6E9"
    }

    MouseArea {
        anchors.fill: parent
    }

    // ---------- 顶部 ----------
    Item {
        id: header
        height: 52
        anchors.top: parent.top
        // 避开挖孔屏 / 状态栏区域
        anchors.topMargin: 16 + libraryPage.SafeArea.margins.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 16
        anchors.rightMargin: 16

        IconButton {
            id: backBtn
            iconSource: libraryPage.iconBase + "chevron-down.svg"
            iconColor: libraryPage.ink
            iconSize: 22
            implicitWidth: 40
            implicitHeight: 40
            rotation: 90
            tooltipText: "返回播放页"
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            onClicked: libraryPage.closeRequested()
        }

        Column {
            anchors.left: backBtn.right
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 1

            Text {
                text: "音乐库"
                color: libraryPage.ink
                font.pixelSize: 18
                font.bold: true
            }
            Text {
                text: libraryPage.songCount + " 首歌曲"
                color: libraryPage.muted
                font.pixelSize: 11
            }
        }
    }

    // ---------- 工具栏 ----------
    // 左侧添加文件（支持多选），右侧批量选择与删除
    Item {
        id: toolbar
        height: 34
        anchors.top: header.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 20
        anchors.rightMargin: 20

        PillButton {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            iconSource: libraryPage.iconBase + "plus.svg"
            text: "添加文件"
            onClicked: openFilesDialog.open()
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            PillButton {
                iconSource: libraryPage.iconBase + "check.svg"
                text: libraryPage.allChecked ? "取消全选" : "全选"
                textColor: libraryPage.allChecked ? libraryPage.accent : libraryPage.ink
                iconColor: libraryPage.allChecked ? libraryPage.accent : libraryPage.ink
                interactive: libraryPage.songCount > 0
                onClicked: libraryPage.store.setAllChecked(!libraryPage.allChecked)
            }

            PillButton {
                iconSource: libraryPage.iconBase + "trash.svg"
                text: libraryPage.hasSelection ? "删除 " + libraryPage.checkedCount : "删除"
                textColor: libraryPage.hasSelection ? "#FFFFFF" : libraryPage.ink
                iconColor: libraryPage.hasSelection ? "#FFFFFF" : libraryPage.ink
                bgColor: libraryPage.hasSelection ? "#E4573A" : libraryPage.surface
                borderColor: libraryPage.hasSelection ? "#E4573A" : libraryPage.hairline
                interactive: libraryPage.hasSelection
                onClicked: {
                    var removed = libraryPage.store.removeChecked()
                    if (removed > 0) libraryPage.showHint("已删除 " + removed + " 首")
                }
            }
        }
    }

    // ---------- 歌曲列表 ----------
    ListView {
        id: songListView
        anchors.top: toolbar.bottom
        anchors.topMargin: 10
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 16
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        clip: true
        spacing: 2
        visible: libraryPage.songCount > 0
        boundsBehavior: Flickable.DragOverBounds
        model: libraryPage.store ? libraryPage.store.model : null

        delegate: Rectangle {
            id: songRow
            required property int index
            required property string file
            required property string title
            required property string artist
            required property string durationText
            required property string format
            required property bool checked

            width: songListView.width
            height: 56
            radius: 10
            color: songRow.checked ? "#1AF3693A"
                 : rowMouse.containsMouse ? "#0D000000"
                 : "transparent"

            Behavior on color { ColorAnimation { duration: 100 } }

            // 行点击：右侧区域播放该曲
            MouseArea {
                id: rowMouse
                anchors.left: parent.left
                anchors.leftMargin: 46
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.right: parent.right
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: libraryPage.playRequested(songRow.index)
            }

            // 文件类型图标：统一音符造型，按格式着色
            FormatIcon {
                id: fileIcon
                file: songRow.file
                format: songRow.format
                size: 28
                anchors.left: checkBox.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
            }

            Column {
                anchors.left: fileIcon.right
                anchors.leftMargin: 10
                anchors.right: durationLabel.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Text {
                    text: songRow.title
                    width: parent.width
                    color: songRow.index === libraryPage.currentIndex ? libraryPage.accent : libraryPage.ink
                    font.pixelSize: 13
                    font.weight: songRow.index === libraryPage.currentIndex ? Font.DemiBold : Font.Normal
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }
                Text {
                    text: songRow.artist
                    width: parent.width
                    color: libraryPage.muted
                    font.pixelSize: 11
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }
            }

            Text {
                id: durationLabel
                text: songRow.durationText
                color: "#B9BDC2"
                font.pixelSize: 11
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
            }

            // 勾选框
            Rectangle {
                id: checkBox
                width: 20
                height: 20
                radius: 6
                anchors.left: parent.left
                anchors.leftMargin: 14
                anchors.verticalCenter: parent.verticalCenter
                color: songRow.checked ? libraryPage.accent : "#FFFFFF"
                border.color: songRow.checked ? libraryPage.accent : "#C2C7CC"
                border.width: 1.5

                Image {
                    id: checkIcon
                    anchors.centerIn: parent
                    source: libraryPage.iconBase + "check.svg"
                    sourceSize: Qt.size(13, 13)
                    width: 13
                    height: 13
                    visible: songRow.checked
                }

                ColorOverlay {
                    anchors.fill: checkIcon
                    source: checkIcon
                    color: "#FFFFFF"
                    visible: songRow.checked
                }

                MouseArea {
                    anchors.fill: parent
                    anchors.margins: -8
                    cursorShape: Qt.PointingHandCursor
                    onClicked: libraryPage.store.setChecked(songRow.index, !songRow.checked)
                }
            }
        }

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }
    }

    // ---------- 空状态 ----------
    Column {
        anchors.centerIn: parent
        spacing: 14
        visible: libraryPage.songCount === 0

        Item {
            width: 44
            height: 44
            anchors.horizontalCenter: parent.horizontalCenter

            Image {
                id: emptyIcon
                anchors.fill: parent
                source: libraryPage.iconBase + "music-note.svg"
                sourceSize: Qt.size(44, 44)
                fillMode: Image.PreserveAspectFit
            }
            ColorOverlay {
                anchors.fill: parent
                source: emptyIcon
                color: "#C2C7CC"
            }
        }

        Text {
            text: "音乐库还是空的"
            color: libraryPage.ink
            font.pixelSize: 15
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            text: "添加本地音乐，开始你的音乐之旅"
            color: libraryPage.muted
            font.pixelSize: 12
            anchors.horizontalCenter: parent.horizontalCenter
        }

        Item {
            width: 120
            height: addFirstSong.height
            anchors.horizontalCenter: parent.horizontalCenter

            PillButton {
                id: addFirstSong
                anchors.horizontalCenter: parent.horizontalCenter
                iconSource: libraryPage.iconBase + "plus.svg"
                text: "添加音乐"
                textColor: "#FFFFFF"
                iconColor: "#FFFFFF"
                bgColor: libraryPage.accent
                borderColor: libraryPage.accent
                onClicked: openFilesDialog.open()
            }
        }
    }

    // ---------- 操作反馈 ----------
    AppToast {
        id: pageToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 28
    }

    // ---------- 文件选择 ----------
    FileDialog {
        id: openFilesDialog
        title: "选择音乐文件"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "音频文件 (*.mp3 *.flac *.wav *.m4a *.aac *.ogg *.wma *.ape *.opus)",
            "所有文件 (*)"
        ]
        onAccepted: {
            var report = libraryPage.store.addFiles(selectedFiles)
            if (report.added > 0) {
                // SAF 地址要持久化权限，重启后才还能访问这些文件
                if (typeof folderScanner !== "undefined") {
                    for (var i = 0; i < selectedFiles.length; ++i)
                        folderScanner.keepPermission(selectedFiles[i])
                }
                libraryPage.showHint("已添加 " + report.added + " 首")
            } else if (report.duplicate > 0) {
                libraryPage.showHint("这些歌曲已经在音乐库里了")
            } else if (report.invalid > 0) {
                libraryPage.showHint("没有可添加的音频文件")
            } else {
                libraryPage.showHint("没有选择任何文件")
            }
        }
    }
}