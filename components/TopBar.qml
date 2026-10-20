import QtQuick

// 顶部栏：歌词页显示返回键，普通页显示右上角菜单键
Item {
    id: bar
    implicitHeight: 48

    property string iconBase: ""
    property bool showBack: false

    signal backClicked()
    signal menuClicked()

    IconButton {
        iconSource: bar.iconBase + "chevron-down.svg"
        iconColor: Theme.ink
        iconSize: 22
        implicitWidth: 40
        implicitHeight: 40
        rotation: 90
        tooltipText: "返回播放页"
        visible: bar.showBack
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        onClicked: bar.backClicked()
    }

    IconButton {
        iconSource: bar.iconBase + "more-vertical.svg"
        iconColor: Theme.ink
        iconSize: 20
        implicitWidth: 40
        implicitHeight: 40
        tooltipText: "菜单"
        visible: !bar.showBack
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: bar.menuClicked()
    }
}
