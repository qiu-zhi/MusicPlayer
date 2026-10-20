import QtQuick
import Qt5Compat.GraphicalEffects

// 胶囊按钮：文字 + 可选图标（iconSource 为空就是纯文字胶囊）。
// 列表管理、空状态、弹窗确认都用它 —— 别再手写一套圆角矩形 + 文字。
// 不可点时设 enabled: false（Item 自带属性，会级联到 MouseArea 并整体置灰）
Item {
    id: pill

    property string iconSource: ""
    property string text: ""
    property color textColor: Theme.ink
    property color iconColor: Theme.ink
    property color bgColor: Theme.surface
    property color borderColor: Theme.hairline
    // 水平内边距总量（左右各一半）。列表头部「一行放三个」的场景调到 18 更紧凑
    property int hPadding: 26

    signal clicked()

    implicitWidth: row.implicitWidth + hPadding
    implicitHeight: 34
    opacity: enabled ? 1 : 0.4

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: height / 2
        color: !pill.enabled ? pill.bgColor
             : mouse.pressed ? Qt.darker(pill.bgColor, 1.08)
             : mouse.containsMouse ? Qt.darker(pill.bgColor, 1.04)
             : pill.bgColor
        border.color: pill.borderColor
        border.width: 1
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: 6

        Item {
            width: 15
            height: 15
            anchors.verticalCenter: parent.verticalCenter
            visible: pill.iconSource !== ""

            Image {
                id: pillIcon
                anchors.fill: parent
                source: pill.iconSource
                sourceSize: Qt.size(15, 15)
                fillMode: Image.PreserveAspectFit
            }

            ColorOverlay {
                anchors.fill: parent
                source: pillIcon
                color: pill.iconColor
            }
        }

        Text {
            text: pill.text
            color: pill.textColor
            font.pixelSize: 12
            anchors.verticalCenter: parent.verticalCenter
            visible: pill.text !== ""
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.clicked()
    }
}