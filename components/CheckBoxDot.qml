import QtQuick
import Qt5Compat.GraphicalEffects

// 勾选框：供播放列表面板在列表管理模式下使用。
// 视觉固定（圆角方块 + 选中时橙色底白勾），点击热区可通过 touchMargin 外扩
Item {
    id: checkBox

    property bool checked: false
    property color accent: Theme.accent
    property int boxSize: 20
    // 视觉之外的额外点击范围，方便手指点
    property real touchMargin: 8

    implicitWidth: boxSize
    implicitHeight: boxSize

    signal toggled()

    Rectangle {
        anchors.fill: parent
        radius: 6
        color: checkBox.checked ? checkBox.accent : Theme.surface
        border.color: checkBox.checked ? checkBox.accent : Theme.disabled
        border.width: 1.5

        Image {
            id: checkIcon
            anchors.centerIn: parent
            source: "../assets/icons/check.svg"
            sourceSize: Qt.size(13, 13)
            width: 13
            height: 13
            visible: checkBox.checked
        }

        ColorOverlay {
            anchors.fill: checkIcon
            source: checkIcon
            color: Theme.surface
            visible: checkBox.checked
        }
    }

    MouseArea {
        anchors.fill: parent
        anchors.margins: -checkBox.touchMargin
        enabled: checkBox.enabled
        cursorShape: Qt.PointingHandCursor
        onClicked: checkBox.toggled()
    }
}
