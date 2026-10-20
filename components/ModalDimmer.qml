import QtQuick

// 遮罩：压暗背景 + 点面板外关闭。
//
// 为什么不用 closePolicy：弹层的 interactive 关掉后（为了不抢列表手势），
// Qt 的 tryClose() 首行 `if (!interactive) return false;`（qquickpopup.cpp:535）
// 会让 CloseOnPressOutside 一起失效，所以这一下点击只能由遮罩接。
//
// 为什么弹层必须 modal: false：Drawer 重写的 blockInput() 末行是 `return modal;`
// （qquickdrawer.cpp），modal 为 true 时弹层外的点击在窗口级就被 overlay 吃掉，
// 遮罩的 MouseArea 永远收不到。非 modal 时由遮罩拦住点击，主界面同样收不到。
Rectangle {
    id: dimmer

    // 要关闭的弹层
    property var popup: null

    color: popup ? Theme.alpha(popup.palette.shadow, 0.5) : Theme.alpha("#000000", 0.5)

    MouseArea {
        anchors.fill: parent
        // 右键也吞掉，否则非 modal 下会穿透到主界面
        acceptedButtons: Qt.AllButtons
        onClicked: {
            if (!dimmer.popup)
                return
            // 面板内没被消费的点击会穿透到这里（列表空白区就不消费点击）。
            // 落在面板上时不动，否则点列表空白处会误关
            var item = dimmer.popup.popupItem
            if (item && item.contains(item.mapFromItem(dimmer, mouseX, mouseY)))
                return
            dimmer.popup.close()
        }
    }
}
