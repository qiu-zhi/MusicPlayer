import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

Item {
    id: playerControls
    width: parent.width
    height: 112

    property bool playing: false
    property real progress: 0.3  // 0.0 - 1.0
    property string currentTime: "1:23"
    property string totalTime: "4:35"
    property int playMode: 0 // 0: 列表循环, 1: 单曲循环, 2: 随机播放

    // 曲库正在重建（扫描文件夹 / 批量导入）。这期间上一首、下一首不可用：
    // 曲库模型正在清空重填，此时按索引取歌会取到错的东西。
    // 与其让按钮点了没反应，不如置灰并把"现在在干什么"说出来。
    property bool busy: false
    property string statusText: ""

    // 拖动进度条时用手柄自身位置驱动显示，松手后等真实进度追上再交还控制权；
    // 否则播放进度回传会和拖动位置互相拉扯，手柄就会抖
    property bool scrubbing: false
    property real scrubRatio: 0

    onProgressChanged: {
        if (scrubbing && !scrubArea.pressed && Math.abs(progress - scrubRatio) < 0.02)
            scrubbing = false
    }

    signal playToggled()
    signal previousClicked()
    signal nextClicked()
    signal seekTo(real value)
    signal playModeCycled()
    signal playlistToggled()
    // 置灰状态下点了切歌按钮。上层据此给一句反馈，别让用户对着死按钮猜
    signal switchBlocked()

    // 图标路径前缀
    readonly property string iconBase: "../assets/icons/"

    // 配色取自唱机素材：近黑主文字 + 金属灰次要 + 番茄橙标签
    readonly property color ink: Theme.ink
    readonly property color muted: Theme.muted
    readonly property color accent: Theme.accent
    readonly property color trackColor: Theme.track
    readonly property color surface: Theme.surface
    readonly property color hairline: Theme.hairline

    // ========== 进度条 ==========
    Item {
        id: progressBar
        width: parent.width - 48
        height: 30
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        // 当前时间
        Text {
            id: currentTimeText
            text: playerControls.currentTime
            color: playerControls.muted
            font.pixelSize: 11
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
        }

        // 总时间。曲库忙时这个位置让给状态提示 —— 右侧本来就是给文字的，
        // 轨道会自动给它让出宽度，不会压到进度条
        Text {
            id: totalTimeText
            text: playerControls.busy ? playerControls.statusText : playerControls.totalTime
            color: playerControls.busy ? playerControls.accent : playerControls.muted
            font.pixelSize: 11
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
        }

        // 进度条轨道
        Rectangle {
            id: track
            height: 4
            anchors.left: currentTimeText.right
            anchors.right: totalTimeText.left
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            color: playerControls.trackColor
            radius: 2

            // 已播放进度
            Rectangle {
                id: progressFill
                height: parent.height
                width: parent.width * (playerControls.scrubbing ? playerControls.scrubRatio : playerControls.progress)
                color: playerControls.accent
                radius: 2
            }

            // 拖拽手柄
            Rectangle {
                id: thumb
                width: 12
                height: 12
                radius: width / 2
                color: Theme.surface
                x: progressFill.width - width / 2
                anchors.verticalCenter: parent.verticalCenter
                visible: scrubArea.containsMouse || scrubArea.pressed

                layer.enabled: true
                layer.effect: DropShadow {
                    radius: 4
                    samples: 8
                    color: Theme.alpha(Theme.accent, 0.55)
                    verticalOffset: 0
                    horizontalOffset: 0
                }
            }

            // 拖拽区域：纵向放宽到 24px，否则 4px 的细轨道很难抓准
            MouseArea {
                id: scrubArea
                height: 24
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: -10
                anchors.rightMargin: -10
                anchors.verticalCenter: parent.verticalCenter
                hoverEnabled: true

                function ratioAt(mx) {
                    // 热区左右各多出 10px，鼠标坐标要先减掉这段偏移才是轨道上的真实位置
                    return Math.max(0, Math.min(1, (mx - 10) / parent.width))
                }

                onPressed: function(mouse) {
                    playerControls.scrubbing = true
                    playerControls.scrubRatio = ratioAt(mouse.x)
                }

                onPositionChanged: function(mouse) {
                    if (pressed) playerControls.scrubRatio = ratioAt(mouse.x)
                }

                // 松手才真正跳转，拖动过程中只更新手柄位置，避免引擎频繁 seek
                onReleased: {
                    if (!playerControls.scrubbing) return
                    playerControls.seekTo(playerControls.scrubRatio)
                    // 暂停时没有新的进度回报，立即复位，避免手柄停在拖动位置
                    if (!playerControls.playing) playerControls.scrubbing = false
                }

                onCanceled: playerControls.scrubbing = false
            }
        }
    }

    // ========== 主控制按钮行（白色浮动胶囊） ==========
    Item {
        id: capsule
        width: parent.width - 48
        height: 64
        anchors.top: progressBar.bottom
        anchors.topMargin: 14
        anchors.horizontalCenter: parent.horizontalCenter

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: playerControls.surface
            border.color: playerControls.hairline
            border.width: 1

            layer.enabled: true
            layer.effect: DropShadow {
                radius: 12
                samples: 16
                color: Theme.alpha(Theme.ink, 0.12)
                verticalOffset: 6
                horizontalOffset: 0
            }
        }

        // 用 RowLayout 而不是 Row：Row 默认顶对齐，54px 的播放按钮和 46px 的
        // 其他按钮顶边对齐时圆心会差 4px，图标就不在一条水平线上
        RowLayout {
            id: controlRow
            anchors.centerIn: parent
            spacing: 16

            // 播放模式
            IconButton {
                id: modeBtn
                iconSource: playerControls.playMode === 0 ? playerControls.iconBase + "repeat.svg" :
                            playerControls.playMode === 1 ? playerControls.iconBase + "repeat-one.svg" :
                            playerControls.iconBase + "shuffle.svg"
                iconColor: playerControls.playMode === 2 ? playerControls.accent : playerControls.muted
                iconSize: 18
                Layout.alignment: Qt.AlignVCenter
                implicitWidth: 46
                implicitHeight: 46
                tooltipText: playerControls.playMode === 0 ? "列表循环" :
                             playerControls.playMode === 1 ? "单曲循环" : "随机播放"
                onClicked: playerControls.playModeCycled()
            }

            // 上一首
            IconButton {
                id: prevBtn
                enabled: !playerControls.busy
                iconSource: playerControls.iconBase + "skip-back.svg"
                iconColor: playerControls.ink
                iconSize: 26
                implicitWidth: 46
                implicitHeight: 46
                Layout.alignment: Qt.AlignVCenter
                tooltipText: playerControls.busy ? playerControls.statusText : "上一首"
                onClicked: playerControls.previousClicked()
                onBlockedClicked: playerControls.switchBlocked()
            }

            // 播放/暂停（主按钮，橙色实心圆）
            IconButton {
                id: playBtn
                iconSource: playerControls.playing ? playerControls.iconBase + "pause.svg" : playerControls.iconBase + "play.svg"
                iconColor: Theme.surface
                iconSize: 28
                implicitWidth: 54
                implicitHeight: 54
                Layout.alignment: Qt.AlignVCenter
                hoverColor: Theme.accentHover
                pressColor: Theme.accentPress
                bgNormalColor: playerControls.accent
                tooltipText: playerControls.playing ? "暂停" : "播放"

                onClicked: playerControls.playToggled()
            }

            // 下一首
            IconButton {
                id: nextBtn
                enabled: !playerControls.busy
                iconSource: playerControls.iconBase + "skip-forward.svg"
                iconColor: playerControls.ink
                iconSize: 26
                implicitWidth: 46
                implicitHeight: 46
                Layout.alignment: Qt.AlignVCenter
                tooltipText: playerControls.busy ? playerControls.statusText : "下一首"
                onClicked: playerControls.nextClicked()
                onBlockedClicked: playerControls.switchBlocked()
            }

            // 播放列表
            IconButton {
                id: listBtn
                iconSource: playerControls.iconBase + "list.svg"
                iconColor: playerControls.muted
                iconSize: 20
                implicitWidth: 46
                implicitHeight: 46
                Layout.alignment: Qt.AlignVCenter
                tooltipText: "播放列表"
                onClicked: playerControls.playlistToggled()
            }
        }
    }
}