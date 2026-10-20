import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

Item {
    id: iconButton
    implicitWidth: 44
    implicitHeight: 44
    property string iconSource: ""
    property color iconColor: Theme.ink
    property int iconSize: 22
    property string tooltipText: ""
    property color hoverColor: Qt.rgba(0, 0, 0, 0.05)
    property color pressColor: Qt.rgba(0, 0, 0, 0.09)
    property color bgNormalColor: "transparent"
    signal clicked()
    // 置灰状态下被点击：点击已被拦下，但上层可以借此给出反馈
    // （用户点了个没反应的东西，是最糟的体验）
    signal blockedClicked()

    // 背景圆
    Rectangle {
        id: bg
        anchors.fill: parent
        color: !iconButton.enabled ? "transparent" :
               mouse.pressed ? iconButton.pressColor :
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

    // SVG 着色。不可用时压成浅灰，让"为什么点不动"一眼可见
    ColorOverlay {
        anchors.fill: iconImg
        source: iconImg
        color: iconButton.enabled ? iconButton.iconColor : Theme.disabled
    }

    // 悬停提示：不管是哪个按钮，鼠标划上去都能知道它的作用。
    // 置灰时也保留提示 —— 那里写的是"为什么现在不能点"
    ToolTip {
        id: tip
        text: iconButton.tooltipText
        visible: iconButton.tooltipText !== "" && mouse.containsMouse
        x: (iconButton.width - implicitWidth) / 2
        y: -implicitHeight - 8
        padding: 6

        background: Rectangle {
            color: Theme.alpha(Theme.ink, 0.92)
            radius: 6
        }
        contentItem: Text {
            text: tip.text
            color: Theme.surface
            font.pixelSize: 11
        }
    }

    // 点击区域。这里刻意不接 enabled：MouseArea 一旦 enabled=false 就收不到
    // hover，置灰时反而看不到提示。改成在这里拦点击 —— 悬停能提示、点了没反应。
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: {
            if (!iconButton.enabled) {
                iconButton.blockedClicked()
                return
            }
            iconButton.clicked()
        }
        cursorShape: iconButton.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
    }
}