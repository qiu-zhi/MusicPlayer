import QtQuick
import Qt5Compat.GraphicalEffects

// 菜单行：图标 + 文字，用于右上角下拉菜单
Item {
    id: menuRow

    property string iconSource: ""
    property string text: ""
    property color iconColor: "#4A4E54"
    property color textColor: "#17181A"

    implicitWidth: 152
    implicitHeight: 40

    signal clicked()

    Rectangle {
        anchors.fill: parent
        radius: 8
        color: rowMouse.pressed ? "#14000000"
             : rowMouse.containsMouse ? "#0A000000"
             : "transparent"
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    Row {
        anchors.fill: parent
        anchors.leftMargin: 10
        spacing: 10

        Item {
            width: 18
            height: 18
            anchors.verticalCenter: parent.verticalCenter

            Image {
                id: rowIcon
                anchors.fill: parent
                source: menuRow.iconSource
                sourceSize: Qt.size(18, 18)
                fillMode: Image.PreserveAspectFit
            }

            ColorOverlay {
                anchors.fill: rowIcon
                source: rowIcon
                color: menuRow.iconColor
            }
        }

        Text {
            text: menuRow.text
            color: menuRow.textColor
            font.pixelSize: 13
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: rowMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: menuRow.clicked()
    }
}
