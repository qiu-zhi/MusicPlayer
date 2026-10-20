import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

pragma ComponentBehavior: Bound

// 输出设备选择面板：基于 Drawer（底部边缘）
//
// 高度固定为「安全视图 × 50%」。设备数量不固定，所以高度**不随列表变化**，
// 超出部分由列表内部滚动承载（滚动条按需显示，让"还能滚"这件事可见）。
//
// 档位 = Auto（默认，蓝牙优先逻辑）+ 系统当前所有输出设备
// 选中结果通过 deviceSelected(deviceId, mode) 回传，由 Main 写入 PlaybackEngine
Drawer {
    id: sheet

    // 当前档位："auto" 或 具体设备 id
    property string selectedId: "auto"

    // 外部注入的设备列表快照，每项 { id, description, label, isDefault, isBt }
    property var devices: []

    // 安全视图高度（窗口高度减系统栏），由外部注入
    property real safeViewHeight: 600
    // 底部安全区（手势条）高度，避免最后一项被挡住。
    // 注意不能叫 bottomInset —— 那是 Popup 的 FINAL 属性（用于背景内缩）
    property real listBottomMargin: 0

    readonly property string iconBase: "../assets/icons/"
    readonly property int rowH: 54

    // 固定为安全视图的一半：设备再多也不改高度，改为列表内滚动
    height: Math.round(safeViewHeight * 0.5)

    signal deviceSelected(string deviceId, string mode)   // mode: "auto" | "manual"

    // ---------- Drawer 自身配置 ----------
    edge: Qt.BottomEdge
    // 同 PlaylistPanel：只在关闭时保留 Drawer 自带的边缘拖拽（用于从屏幕底边划出打开），
    // 打开后关掉。否则它会在列表还没接手手势时把竖向拖动判成「拖抽屉」，
    // 表现就是「滑设备列表把整个抽屉一起带着滑」。
    // 详细源码依据见 PlaylistPanel.qml 里 interactive 的注释。
    interactive: !opened
    modal: false      // 同 PlaylistPanel：modal 会把遮罩上的点击在窗口级吞掉
    dim: true
    Overlay.modeless: ModalDimmer {
        popup: sheet
    }
    padding: 0
    background: Rectangle {
        color: Theme.surface
        radius: 16
        border.color: Theme.edge
        border.width: 1

        // 抽屉贴屏幕底边：补掉下方圆角
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
        color: Theme.track
    }

    // ---------- 标题 ----------
    Text {
        id: title
        anchors.top: handle.bottom
        anchors.topMargin: 12
        anchors.left: parent.left
        anchors.leftMargin: 18
        text: "选择输出设备"
        color: Theme.ink
        font.pixelSize: 14
        font.weight: Font.DemiBold
    }

    // ---------- 档位列表（内容超出时滚动） ----------
    ListView {
        id: deviceList
        anchors.top: title.bottom
        anchors.topMargin: 10
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 14 + sheet.listBottomMargin
        clip: true
        spacing: 2
        boundsBehavior: Flickable.DragOverBounds

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
            color: rowMouse.pressed ? Theme.alpha(Theme.accent, 0.10)
                 : rowMouse.containsMouse ? Theme.alpha("#000000", 0.04)
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
                        color: devRow.selected ? Theme.accent : Theme.muted
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
                        color: devRow.selected ? Theme.accent : Theme.ink
                        font.pixelSize: 13
                        font.weight: devRow.selected ? Font.DemiBold : Font.Normal
                        maximumLineCount: 1
                        elide: Text.ElideRight
                    }

                    Text {
                        width: parent.width
                        visible: text !== ""
                        text: devRow.modelData.subtitle
                        color: Theme.muted
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
                        color: Theme.accent
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

        // 设备多时能看到滚动条，明确"还能滚"
        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }
    }

    // ---------- 顶部拖动关闭 ----------
    // interactive 在打开时被关掉了，这里补回「下滑关闭」，
    // 并且只覆盖把手 + 标题这一条 —— 不与下面的设备列表重叠，
    // 所以滑列表永远不会带动抽屉，拖抽屉也永远不会误触发列表滚动
    MouseArea {
        id: dragArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: title.y + title.height + 8

        property real pressX: 0
        property real pressY: 0

        onPressed: function(mouse) {
            pressX = mouse.x
            pressY = mouse.y
        }

        onReleased: function(mouse) {
            var dx = mouse.x - pressX
            var dy = mouse.y - pressY
            // 竖向为主且拖够了才关，避免横向划一下也把面板收掉
            if (Math.abs(dy) <= Math.abs(dx)) return
            if (dy > 60) sheet.close()
        }
    }
}
