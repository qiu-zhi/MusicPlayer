import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

// 右上角下拉菜单：添加单曲 / 扫描文件夹 / 关于
// 只负责展示与收起，具体动作由外部响应信号完成
Popup {
    id: moreMenu
    width: 168
    padding: 8
    modal: true
    closePolicy: Popup.CloseOnPressOutside
    transformOrigin: Item.TopRight

    // 锚点：菜单左上角位置由外部按目标按钮定位
    property real anchorX: 0
    property real anchorY: 0
    x: anchorX - width
    y: anchorY

    // 图标路径前缀，由外部（Main.qml）传入
    property string iconBase: ""

    signal addSongRequested()
    signal scanFolderRequested()
    signal outputDeviceRequested()
    signal aboutRequested()

    background: Rectangle {
        radius: 12
        color: "#FFFFFF"
        border.color: "#E4E6E9"
        border.width: 1

        layer.enabled: true
        layer.effect: DropShadow {
            radius: 16
            samples: 16
            color: "#1F17181A"
            verticalOffset: 6
            horizontalOffset: 0
        }
    }

    contentItem: Column {
        spacing: 2

        MenuRow {
            width: 152
            iconSource: moreMenu.iconBase + "plus.svg"
            text: "添加单曲"
            onClicked: {
                moreMenu.close()
                moreMenu.addSongRequested()
            }
        }

        MenuRow {
            width: 152
            iconSource: moreMenu.iconBase + "folder.svg"
            text: "扫描文件夹"
            onClicked: {
                moreMenu.close()
                moreMenu.scanFolderRequested()
            }
        }

        MenuRow {
            width: 152
            iconSource: moreMenu.iconBase + "speaker.svg"
            text: "输出设备"
            onClicked: {
                moreMenu.close()
                moreMenu.outputDeviceRequested()
            }
        }

        MenuRow {
            width: 152
            iconSource: moreMenu.iconBase + "info.svg"
            text: "关于"
            onClicked: {
                moreMenu.close()
                moreMenu.aboutRequested()
            }
        }
    }

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 120 }
        NumberAnimation { property: "scale"; from: 0.92; to: 1; duration: 140; easing.type: Easing.OutCubic }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 100 }
    }
}
