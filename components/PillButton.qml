import QtQuick
import Qt5Compat.GraphicalEffects

// 胶囊按钮：图标 + 文字，用于音乐库工具栏与空状态
Item {
    id: pill

    property string iconSource: ""
    property string text: ""
    property color textColor: "#17181A"
    property color iconColor: "#17181A"
    property color bgColor: "#FFFFFF"
    property color borderColor: "#E4E6E9"
    property bool interactive: true

    signal clicked()

    implicitWidth: row.implicitWidth + 26
    implicitHeight: 34
    opacity: interactive ? 1 : 0.4

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: height / 2
        color: !pill.interactive ? pill.bgColor
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
        enabled: pill.interactive
        cursorShape: Qt.PointingHandCursor
        onClicked: pill.clicked()
    }
}