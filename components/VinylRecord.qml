import QtQuick

// 黑胶唱片：素材已按盘面裁切，图片边界即盘面边缘
Item {
    id: vinylRecord
    implicitWidth: 240
    implicitHeight: 240

    property bool playing: false
    property real rotationSpeed: 20 // 每秒旋转的角度

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
    }
}