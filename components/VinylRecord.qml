import QtQuick
import Qt5Compat.GraphicalEffects

// 黑胶唱片：素材已按盘面裁切，图片边界即盘面边缘
Item {
    id: vinylRecord
    implicitWidth: 240
    implicitHeight: 240

    property bool playing: false
    property string coverSource: ""
    property real rotationSpeed: 20 // 每秒旋转的角度

    // 素材中橙色中心标签直径占整张唱片直径的比例
    readonly property real labelRatio: 0.409

    Item {
        id: disc
        anchors.fill: parent

        // 匀速自转：暂停时冻结在当前角度，恢复播放时从原角度继续
        RotationAnimation on rotation {
            running: true
            paused: !vinylRecord.playing
            loops: Animation.Infinite
            from: 0
            to: 360
            duration: 360000 / vinylRecord.rotationSpeed
            direction: RotationAnimation.Clockwise
        }

        Image {
            anchors.fill: parent
            source: "../assets/images/cut/vinyl-record.png"
            sourceSize: Qt.size(width, height)
            fillMode: Image.PreserveAspectFit
            smooth: true
            mipmap: true
        }

        // 有封面时贴在中心标签上，跟着唱片一起转
        Item {
            id: labelArea
            anchors.centerIn: parent
            width: disc.width * vinylRecord.labelRatio
            height: width
            visible: vinylRecord.coverSource !== ""

            Image {
                id: coverImage
                anchors.fill: parent
                source: vinylRecord.coverSource
                sourceSize: Qt.size(width, height)
                fillMode: Image.PreserveAspectCrop
                visible: false
            }

            Rectangle {
                id: labelMask
                anchors.fill: parent
                radius: width / 2
                color: "black"
                visible: false
            }

            OpacityMask {
                anchors.fill: parent
                source: coverImage
                maskSource: labelMask
            }
        }
    }
}