import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

Item {
    id: iconButton
    implicitWidth: 44
    implicitHeight: 44
    property string iconSource: ""
    property color iconColor: "#17181A"
    property int iconSize: 22
    property string tooltipText: ""
    property color hoverColor: Qt.rgba(0, 0, 0, 0.05)
    property color pressColor: Qt.rgba(0, 0, 0, 0.09)
    property color bgNormalColor: "transparent"
    signal clicked()

    // 背景圆
    Rectangle {
        id: bg
        anchors.fill: parent
        color: mouse.pressed ? iconButton.pressColor :
               mouse.containsMouse ? iconButton.hoverColor :
               iconButton.bgNormalColor
        radius: width / 2
        Behavior on color { ColorAnimation { duration: 100 } }
    }

    // 图标
    Image {
        id: iconImg
        source: iconButton.iconSource
        sourceSize: Qt.size(iconButton.iconSize, iconButton.iconSize)
        width: iconButton.iconSize
        height: iconButton.iconSize
        anchors.centerIn: parent
    }

    // SVG 着色
    ColorOverlay {
        anchors.fill: iconImg
        source: iconImg
        color: iconButton.iconColor
    }

    // 悬停提示：不管是哪个按钮，鼠标划上去都能知道它的作用
    ToolTip {
        id: tip
        text: iconButton.tooltipText
        visible: iconButton.tooltipText !== "" && mouse.containsMouse
        x: (iconButton.width - implicitWidth) / 2
        y: -implicitHeight - 8
        padding: 6

        background: Rectangle {
            color: "#EB17181A"
            radius: 6
        }
        contentItem: Text {
            text: tip.text
            color: "#FFFFFF"
            font.pixelSize: 11
        }
    }

    // 点击区域
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: iconButton.clicked()
        cursorShape: Qt.PointingHandCursor
    }
}