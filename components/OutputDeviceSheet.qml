import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

pragma ComponentBehavior: Bound

// 输出设备选择面板：从底部上滑的 Bottom Sheet
// 档位 = Auto（默认，蓝牙优先逻辑）+ 系统当前所有输出设备
// 选择结果通过 deviceSelected(deviceId, mode) 回传，由 Main 写入 PlaybackEngine
Item {
    id: sheet

    // 当前档位："auto" 或 具体设备 id
    property string selectedId: "auto"

    // 外部注入的设备列表快照，每项 { id, description, isDefault }
    property var devices: []

    readonly property string iconBase: "../assets/icons/"

    // 拖动位移：向外暴露，由 Main 叠加到面板整体 y 上
    property real dragOffset: 0

    signal deviceSelected(string deviceId, string mode)   // mode: "auto" | "manual"
    signal dismissed()

    readonly property int rowH: 54
    readonly property int headerBlockH: 78          // 把手 + 标题占位
    readonly property int maxVisibleRows: 6         // 超过则列表内部滚动

    // 实际要展示的行数（Auto 一行 + 设备若干）
    readonly property int rowCount: 1 + devices.length
    readonly property int visibleRows: Math.min(rowCount, maxVisibleRows)

    // 面板总高：头部 + 行高 × 可见行数 + 底部留白
    readonly property int sheetHeight: headerBlockH + visibleRows * rowH + 16

    // ---------- 背景 ----------
    Rectangle {
        anchors.fill: parent
        radius: 16
        color: "#FFFFFF"
        border.color: "#E1E3E7"
        border.width: 1

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.radius
            color: parent.color
        }
    }

    // ---------- 把手 ----------
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

    // ---------- 标题 ----------
    Text {
        id: title
        anchors.top: handle.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.leftMargin: 18
        text: "选择输出设备"
        color: "#17181A"
        font.pixelSize: 14
        font.weight: Font.DemiBold
    }

    // ---------- 档位列表 ----------
    ListView {
        id: deviceList
        anchors.top: title.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14 + sheet.SafeArea.margins.bottom
        clip: true
        spacing: 2
        boundsBehavior: Flickable.DragOverBounds
        interactive: contentHeight > height

        model: {
            var rows = [{
                devId: "auto",
                title: "自动（Auto）",
                subtitle: "蓝牙优先，其余跟随系统默认",
                isDefault: false,
                isBt: false
            }]
            for (var i = 0; i < sheet.devices.length; ++i) {
                var d = sheet.devices[i]
                rows.push({
                    devId: "" + d.id,
                    // label 是引擎翻译过的可读名（如「显示器 (VX2478-2)」），
                    // 没有 label 时退回系统原名
                    title: ("" + (d.label || d.description)),
                    subtitle: d.isDefault ? "系统默认设备" : "",
                    isDefault: d.isDefault,
                    isBt: d.isBt === true
                })
            }
            return rows
        }

        delegate: Rectangle {
            id: devRow
            required property var modelData

            readonly property bool selected: sheet.selectedId === modelData.devId
            readonly property bool isAuto: modelData.devId === "auto"

            width: deviceList.width
            height: sheet.rowH
            radius: 8
            color: rowMouse.pressed ? "#1AF3693A"
                 : rowMouse.containsMouse ? "#0A000000"
                 : "transparent"
            Behavior on color { ColorAnimation { duration: 100 } }

            Row {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 12

                // 设备图标
                Item {
                    width: 20
                    height: 20
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                        id: devIcon
                        anchors.fill: parent
                        source: devRow.isAuto
                                ? sheet.iconBase + "check.svg"
                                : (devRow.modelData.isBt
                                   ? sheet.iconBase + "headphone.svg"
                                   : sheet.iconBase + "speaker.svg")
                        sourceSize: Qt.size(20, 20)
                        fillMode: Image.PreserveAspectFit
                        visible: false
                        smooth: true
                    }

                    ColorOverlay {
                        anchors.fill: devIcon
                        source: devIcon
                        color: devRow.selected ? "#F3693A" : "#8A8D92"
                    }
                }

                // 名称 + 副标题
                Column {
                    width: parent.width - 20 - 24 - 24
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        width: parent.width
                        text: devRow.modelData.title
                        color: devRow.selected ? "#F3693A" : "#17181A"
                        font.pixelSize: 13
                        font.weight: devRow.selected ? Font.DemiBold : Font.Normal
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: devRow.modelData.subtitle
                        color: "#8A8D92"
                        font.pixelSize: 11
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }
                }

                // 选中标记
                Item {
                    width: 18
                    height: 18
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: devRow.selected ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 120 } }

                    Image {
                        id: tickIcon
                        anchors.fill: parent
                        source: sheet.iconBase + "check.svg"
                        sourceSize: Qt.size(18, 18)
                        visible: false
                    }

                    ColorOverlay {
                        anchors.fill: tickIcon
                        source: tickIcon
                        color: "#F3693A"
                    }
                }
            }

            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    var mode = devRow.isAuto ? "auto" : "manual"
                    sheet.selectedId = devRow.modelData.devId
                    sheet.deviceSelected(devRow.modelData.devId, mode)
                }
            }
        }

        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AlwaysOff }
    }

    // ---------- 拖动收起 ----------
    MouseArea {
        id: handleArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: sheet.headerBlockH

        property real pressY: 0

        onPressed: function(mouse) {
            pressY = mouse.y
        }

        onPositionChanged: function(mouse) {
            if (!pressed) return
            var dy = mouse.y - pressY
            sheet.dragOffset = dy > 0 ? Math.min(dy, sheet.height) : 0
        }

        onReleased: {
            if (sheet.dragOffset > 60) sheet.dismissed()
            sheet.dragOffset = 0
        }

        onCanceled: sheet.dragOffset = 0
    }
}
