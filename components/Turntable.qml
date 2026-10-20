import QtQuick
import Qt5Compat.GraphicalEffects

// 唱机三层叠加：底层底座 → 中层旋转的黑胶唱片 → 顶层唱臂
// 三个比例均来自素材实测，改素材时同步更新即可
Item {
    id: turntable

    property bool playing: false

    // 底座素材 700x697
    readonly property real baseAspect: 700 / 697

    // 底座凹槽（唱盘位）圆心，按底座宽高归一化
    readonly property real wellXRatio: 0.4726
    readonly property real wellYRatio: 0.4865

    // 唱片直径、唱臂宽度、唱臂左上角位置，均按底座宽度归一化
    readonly property real recordRatio: 0.7757
    readonly property real armWidthRatio: 0.4913
    readonly property real armXRatio: 0.4654
    readonly property real armYRatio: 0.0670

    implicitWidth: 290
    implicitHeight: width / baseAspect

    Image {
        id: base
        anchors.fill: parent
        source: "../assets/images/cut/turntable-base.png"
        sourceSize: Qt.size(width, height)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true

        // 底座与页面底色接近，加一层柔和投影把机身从背景里托出来
        layer.enabled: true
        layer.effect: DropShadow {
            radius: 18
            samples: 24
            color: Theme.alpha(Theme.ink, 0.18)
            verticalOffset: 10
            horizontalOffset: 0
        }
    }

    // 中层：唱片圆心落在底座凹槽中心
    VinylRecord {
        width: turntable.width * turntable.recordRatio
        height: width
        x: turntable.width * turntable.wellXRatio - width / 2
        y: turntable.height * turntable.wellYRatio - height / 2
        playing: turntable.playing
    }

    // 顶层：唱臂枢轴落在底座右上方
    ToneArm {
        width: turntable.width * turntable.armWidthRatio
        height: implicitHeight
        x: turntable.width * turntable.armXRatio
        y: turntable.height * turntable.armYRatio
        playing: turntable.playing
    }
}