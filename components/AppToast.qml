import QtQuick

// 轻提示：短消息浮层，显示约 1.8 秒后自动淡出
Rectangle {
    id: toast

    property string text: ""

    implicitWidth: toastLabel.implicitWidth + 28
    implicitHeight: 34
    radius: 17
    color: Theme.alpha(Theme.ink, 0.92)
    opacity: toast.text !== "" ? 1 : 0
    visible: opacity > 0
    z: 500

    Behavior on opacity { NumberAnimation { duration: 160 } }

    Text {
        id: toastLabel
        anchors.centerIn: parent
        text: toast.text
        color: Theme.surface
        font.pixelSize: 12
    }

    Timer {
        interval: 1800
        running: toast.text !== ""
        onTriggered: toast.text = ""
    }
}
