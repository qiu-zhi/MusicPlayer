import QtQuick
import QtQuick.Controls
import Qt5Compat.GraphicalEffects

// 「关于」弹窗：应用图标 + 版本 + 支持平台 + 构建信息
// 纯展示，无业务逻辑；appVersion 由 C++ 注入到根上下文
Popup {
    id: aboutPopup
    width: 340
    // 高度写死：contentItem 里的 id 在组件作用域外不可见，不能反查 implicitHeight
    height: 272
    modal: true
    closePolicy: Popup.CloseOnPressOutside
    padding: 0

    background: Rectangle {
        radius: 16
        color: "#FFFFFF"
        border.color: "#E4E6E9"
        border.width: 1

        layer.enabled: true
        layer.effect: DropShadow {
            radius: 24
            samples: 24
            color: "#3317181A"
            verticalOffset: 12
            horizontalOffset: 0
        }
    }

    contentItem: Column {
        spacing: 8
        topPadding: 28
        bottomPadding: 22
        leftPadding: 24
        rightPadding: 24
        // 宽度取弹窗内容区宽度，子项在块内自行对齐
        width: 340 - 48

        // 应用图标：与桌面/启动器图标同源
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 64
            height: 64
            // 组件在 components/ 下，素材在应用根，需要退一级
            source: "../assets/app-icon/ic_launcher_play_store_512.png"
            sourceSize: Qt.size(64, 64)
            fillMode: Image.PreserveAspectFit
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Music Player v" + appVersion
            color: "#17181A"
            font.pixelSize: 16
            font.bold: true
        }

        // 内容块：整体居中，块内文本左对齐
        // 用 Item 包裹：Item 宽度取内容宽度并居中，Text 左对齐，实现「块居中 + 文本左对齐」
        Item {
            width: childrenRect.width
            height: childrenRect.height
            anchors.horizontalCenter: parent.horizontalCenter
            Text {
                text: "支持 Windows（Win7 除外）、Android"
                color: "#8A8D92"
                font.pixelSize: 12
                lineHeight: 1.4
                horizontalAlignment: Text.AlignLeft
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: 340 - 48
            text: "Built on 2026/10/12 based on Qt 6.12 (MinGW 13.1.0, x86_64)"
            color: "#8A8D92"
            font.pixelSize: 12
            lineHeight: 1.4
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
        }

        PillButton {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "知道了"
            textColor: "#FFFFFF"
            iconColor: "#FFFFFF"
            bgColor: "#F3693A"
            borderColor: "#F3693A"
            onClicked: aboutPopup.close()
        }
    }

    enter: Transition {
        NumberAnimation { property: "opacity"; from: 0; to: 1; duration: 140 }
        NumberAnimation { property: "scale"; from: 0.9; to: 1; duration: 160; easing.type: Easing.OutCubic }
    }
    exit: Transition {
        NumberAnimation { property: "opacity"; to: 0; duration: 100 }
    }
}
