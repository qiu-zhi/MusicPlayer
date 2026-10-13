import QtQuick

// 唱臂：以枢轴为圆心摆动，播放时把唱针移进唱片，暂停时移出唱片
Item {
    id: toneArm
    property bool playing: false

    // 素材 tonearm.png 为 1264x1284，枢轴（圆形底座）位于 85.52% / 14.17% 处
    readonly property real assetAspect: 1264 / 1284
    readonly property real pivotXRatio: 0.8552
    readonly property real pivotYRatio: 0.1417

    // 素材中唱臂的自然朝向约为 133.14°，下面两个角度是相对该朝向的旋转量。
    // 唱针沿垂直于臂身的方向移动，因此让臂身接近竖直，进场才会是从右往左横扫，
    // 而不是自上而下落下。播放：臂身 117°（唱针落在唱片中内侧）；暂停：臂身 90°（唱针停在右侧片外）。
    property real playAngle: -16.1
    property real restAngle: -43.1

    implicitWidth: 150
    implicitHeight: width / assetAspect

    Image {
        id: armImage
        anchors.fill: parent
        source: "../assets/images/cut/tonearm.png"
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        antialiasing: true

        // 绕枢轴摆动，而不是绕图片中心
        transform: Rotation {
            origin.x: armImage.paintedWidth * toneArm.pivotXRatio + (armImage.width - armImage.paintedWidth) / 2
            origin.y: armImage.paintedHeight * toneArm.pivotYRatio + (armImage.height - armImage.paintedHeight) / 2
            angle: toneArm.playing ? toneArm.playAngle : toneArm.restAngle

            Behavior on angle {
                NumberAnimation {
                    duration: 420
                    easing.type: Easing.InOutQuad
                }
            }
        }
    }
}