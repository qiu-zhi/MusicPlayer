import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

pragma ComponentBehavior: Bound

// 播放列表面板：基于 Drawer（底部边缘），兼音乐库管理
// 原「音乐库」整页已并入这里，不再有独立页面
//
// 为什么用 Drawer：遮罩 / 点击外部关闭 / 边缘划出 / 进出动画都由它提供，
// 不用再手写这些。
//
// ⚠️ 关于「60% 停靠档」：实测（Qt 6.12）Drawer 的 position 一旦被 open() 触发，
//    就会被内部动画强制推到 1.0，预设的 0.6 会被覆盖，用 visible 绕过也一样。
//    所以 60% 不能用 position 表达，改用 **height**：
//      停靠档 = 安全视图 × 0.6，铺满档 = 安全视图 × 1.0
//    抽屉本身始终是全开（position = 1.0），靠高度变化表现两档。
//
// 编辑（列表管理）模式：点「列表管理」进入 —— 换成「全选」「删除」，右上角多一个
// 「退出列表管理」。列表项左侧出现勾选框。删除语义随当前列表变化：
//   全部列表 → 只从列表移出，不动磁盘文件
//   喜欢列表 → 只取消喜欢，曲目仍留在全部列表
Drawer {
    id: panel

    property var allSongs: null       // 全部歌曲 ListModel
    property var likedSongs: null     // 我喜欢的 ListModel
    property string currentFile: ""   // 正在播放的歌曲文件，用于高亮
    property bool showLiked: false    // 当前视图：false 全部 / true 我喜欢的

    // 安全视图高度（窗口高度减系统栏），由外部注入
    property real safeViewHeight: 600
    // 底部安全区（手势条）高度，避免列表最后一项被挡住。
    // 注意：不能叫 bottomInset —— 那是 Popup 的 FINAL 属性（用于背景内缩），
    // 重名会在运行时报「Cannot override FINAL property」
    property real listBottomMargin: 0

    readonly property real dockRatio: 0.6
    // 是否铺满：false = 停靠 60%，true = 铺满安全视图
    property bool expanded: false

    height: Math.round(safeViewHeight * (expanded ? 1.0 : dockRatio))
    Behavior on height {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
    }

    // ---------- Drawer 自身配置 ----------
    edge: Qt.BottomEdge
    // 只在关闭时保留 Drawer 自带的边缘拖拽（唯一作用是「从底边划出打开」）。
    // 打开后必须关掉：qquickdrawer.cpp 的 grabTouch 里，只要 position > 0，面板内
    // 超过 20px 的竖向拖动就判成「拖抽屉」；而列表行不设 keepTouchGrab、ListView 又
    // 要等真正起滑才置位 → 手势会被抽屉抢走（滑列表带着整个抽屉一起滑）。
    // 关掉后的分工：底边 → Drawer 打开；顶部把手 → 两档切换与收起；列表 → 只归 ListView。
    interactive: !opened
    // ⚠️ 必须 false。Drawer 重写的 blockInput() 末行是 `return modal;`
    // （qquickdrawer.cpp: QQuickDrawerPrivate::blockInput），modal 为 true 时
    // 弹层外的所有点击在窗口级就被 overlay 的事件过滤器吃掉，遮罩上的 MouseArea
    // 根本收不到 —— 表现为「点外部没反应」。非 modal 时遮罩自己拦住点击，
    // 主界面同样收不到事件，效果与 modal 一致。
    modal: false
    // 非 modal 走 modeless 遮罩（modal 用的那个在 modal: false 下不创建）
    dim: true
    Overlay.modeless: ModalDimmer {
        popup: panel
    }
    padding: 0
    // 弹出层用窗口坐标，内部子项以 contentItem 为 parent
    background: Rectangle {
        color: Theme.surface
        radius: 16
        border.color: Theme.edge
        border.width: 1

        // 抽屉贴屏幕底边：补掉下方圆角
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: parent.radius
            color: parent.color
        }
    }

    // ---------- 编辑（列表管理）模式 ----------
    property bool editing: false

    // 勾选的文件集合：file -> true。
    // 刻意放在面板本地而不是模型里 —— 喜欢列表每次数据变化都会整体重建，
    // 状态挂在模型上会被冲掉。
    property var checkedFiles: ({})
    // 勾选变化计数，用来给 isChecked / allActiveChecked 建立绑定依赖
    property int checkedRevision: 0
    readonly property int checkedCount: {
        checkedRevision
        return Object.keys(checkedFiles).length
    }

    readonly property string iconBase: "../assets/icons/"
    readonly property int allCount: allSongs ? allSongs.count : 0
    readonly property int likedCount: likedSongs ? likedSongs.count : 0
    readonly property int activeCount: showLiked ? likedCount : allCount
    readonly property var activeSongs: showLiked ? likedSongs : allSongs

    signal itemClicked(string file, bool likedView)
    signal removeRequested(var files, bool likedView)
    signal addMusicRequested()

    // 当前左滑展开的那一行（空串 = 全部收起）。同时只允许一行展开
    property string swipedFile: ""

    // 每次打开都复位：回到 60% 停靠档，退出列表管理并清空勾选
    function resetState() {
        expanded = false
        editing = false
        swipedFile = ""
        clearChecked()
    }

    // ---------- 勾选辅助 ----------
    function isChecked(file) {
        checkedRevision                    // 建立依赖：勾选变化时刷新
        return checkedFiles[file] === true
    }

    function setChecked(file, value) {
        var next = {}
        for (var k in checkedFiles) {
            if (checkedFiles[k] && k !== file) next[k] = true
        }
        if (value) next[file] = true
        checkedFiles = next
        checkedRevision++
    }

    function clearChecked() {
        checkedFiles = ({})
        checkedRevision++
    }

    // 当前视图里的全部文件
    function activeFiles() {
        var out = []
        var m = panel.activeSongs
        if (!m) return out
        for (var i = 0; i < m.count; ++i) out.push(m.get(i).file)
        return out
    }

    function allActiveChecked() {
        checkedRevision
        var files = activeFiles()
        if (files.length === 0) return false
        for (var i = 0; i < files.length; ++i) {
            if (checkedFiles[files[i]] !== true) return false
        }
        return true
    }

    function checkAllActive() {
        var files = activeFiles()
        var next = {}
        for (var i = 0; i < files.length; ++i) next[files[i]] = true
        checkedFiles = next
        checkedRevision++
    }

    // 当前视图里被勾选的文件
    function activeCheckedFiles() {
        var out = []
        var files = activeFiles()
        for (var i = 0; i < files.length; ++i) {
            if (checkedFiles[files[i]] === true) out.push(files[i])
        }
        return out
    }

    function commitRemove() {
        var files = activeCheckedFiles()
        if (files.length === 0) return 0
        var liked = panel.showLiked
        panel.removeRequested(files, liked)
        clearChecked()
        return files.length
    }

    // 把手
    Rectangle {
        id: handle
        anchors.top: parent.top
        anchors.topMargin: 8
        anchors.horizontalCenter: parent.horizontalCenter
        width: 40
        height: 4
        radius: 2
        color: Theme.track
    }

    // 头部：标题 + 文字胶囊操作区（同一行）。
    // 「编辑」与「全选 / 删除 / 退出」互斥显示，编辑态按钮虽多但省掉了「编辑」本身，
    // 实测 360dp 宽度下放得下；极长标题由 elide 截断兜底
    Item {
        id: header
        width: parent.width - 24
        height: 44
        anchors.top: handle.bottom
        anchors.topMargin: 6
        anchors.left: parent.left
        anchors.leftMargin: 12

        Text {
            id: headerTitle
            text: panel.showLiked
                  ? "我喜欢的音乐 (" + panel.likedCount + ")"
                  : "播放列表 (" + panel.allCount + ")"
            color: Theme.ink
            font.pixelSize: 14
            font.weight: Font.DemiBold
            anchors.left: parent.left
            anchors.right: actionRow.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            maximumLineCount: 1
        }

        Row {
            id: actionRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 6

            // 普通模式：进入列表管理
            PillButton {
                text: "编辑"
                hPadding: 18
                visible: !panel.editing
                enabled: panel.activeCount > 0
                onClicked: {
                    panel.clearChecked()
                    panel.editing = true
                }
            }

            // 编辑模式：全选（再点一次取消全选）
            PillButton {
                text: panel.allActiveChecked() ? "取消全选" : "全选"
                hPadding: 16
                visible: panel.editing
                enabled: panel.activeCount > 0
                onClicked: {
                    if (panel.allActiveChecked()) panel.clearChecked()
                    else panel.checkAllActive()
                }
            }

            // 编辑模式：删除（喜欢列表里语义是取消喜欢），带选中数量
            PillButton {
                text: (panel.showLiked ? "取消喜欢" : "删除")
                      + (panel.checkedCount > 0 ? " " + panel.checkedCount : "")
                hPadding: 16
                textColor: Theme.danger
                visible: panel.editing
                enabled: panel.checkedCount > 0
                onClicked: panel.commitRemove()
            }

            // 编辑模式：退出（进去之后必须能出来）
            PillButton {
                text: "退出"
                hPadding: 16
                visible: panel.editing
                onClicked: {
                    panel.clearChecked()
                    panel.editing = false
                }
            }
        }
    }

    // 全部 / 我喜欢的 分段切换
    Rectangle {
        id: viewSwitch
        height: 32
        anchors.top: header.bottom
        anchors.topMargin: 6
        anchors.left: header.left
        anchors.right: header.right
        radius: 9
        color: Theme.fill

        // 选中滑块：只让它滑动，避免两个分段同时变色造成闪烁
        Rectangle {
            id: thumb
            width: (viewSwitch.width - 9) / 2
            height: viewSwitch.height - 6
            y: 3
            x: 3 + (panel.showLiked ? width + 3 : 0)
            radius: 7
            color: Theme.surface
            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }

        Row {
            anchors.fill: parent
            anchors.margins: 3
            spacing: 3

            Repeater {
                model: [
                    { label: "全部", liked: false },
                    { label: "我喜欢的", liked: true }
                ]

                delegate: Item {
                    id: segItem
                    required property var modelData

                    readonly property bool selected: panel.showLiked === modelData.liked

                    width: (viewSwitch.width - 9) / 2
                    height: parent.height

                    Text {
                        anchors.centerIn: parent
                        text: segItem.modelData.label
                        color: segItem.selected ? Theme.accent : Theme.muted
                        font.pixelSize: 12
                        font.weight: segItem.selected ? Font.DemiBold : Font.Normal
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            // 切视图时清空勾选：两个列表的文件集合不同，
                            // 留着勾选会让「删除」作用到看不见的项上
                            panel.clearChecked()
                            panel.showLiked = segItem.modelData.liked
                        }
                    }
                }
            }
        }
    }

    // ---------- 列表 ----------
    ListView {
        id: listView
        anchors.top: viewSwitch.bottom
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: 6
        anchors.bottomMargin: 12 + panel.listBottomMargin
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        clip: true
        spacing: 2
        visible: panel.activeCount > 0
        boundsBehavior: Flickable.DragOverBounds
        // 一开始滑列表就收起左滑的删除键，避免「滑走了还开着」
        onMovementStarted: panel.swipedFile = ""

        // 删除一行后其余行平滑上移，不然是瞬间跳位
        displaced: Transition {
            NumberAnimation { properties: "x,y"; duration: 220; easing.type: Easing.OutCubic }
        }

        model: panel.activeSongs

        delegate: Item {
            id: rowItem
            required property int index
            required property string file
            required property string title
            required property string artist
            required property string durationText
            required property string format
            required property bool liked

            readonly property bool current: file === panel.currentFile
            readonly property bool picked: panel.isChecked(rowItem.file)
            // 左滑露出的删除键宽度（只放一个图标，不用太宽）
            readonly property int revealWidth: 56

            width: listView.width
            height: 50

            // 别的行被划开时，自己平滑收起
            Connections {
                target: panel
                function onSwipedFileChanged() {
                    if (panel.swipedFile !== rowItem.file)
                        rowItem.closeRow()
                }
            }

            // 收起这一行（带吸附动画）。供外部与自身复用
            function closeRow() {
                if (rowContent.x !== 0) snapBack.start()
            }

            // ---- 底层：删除键（划开后露出来）----
            Rectangle {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: rowItem.revealWidth
                height: parent.height
                radius: 8
                // 拖拽中或已停靠才显示：静止时不出现，也杜绝透色
                visible: rowMouse.drag.active || rowContent.x < -0.5
                color: deleteMouse.pressed ? Qt.darker(Theme.danger, 1.12) : Theme.danger

                Image {
                    anchors.centerIn: parent
                    source: panel.iconBase + "trash.svg"
                    sourceSize: Qt.size(20, 20)
                    width: 20
                    height: 20
                }

                MouseArea {
                    id: deleteMouse
                    anchors.fill: parent
                    onClicked: {
                        rowItem.closeRow()
                        panel.swipedFile = ""
                        panel.removeRequested([rowItem.file], panel.showLiked)
                    }
                }
            }

            // ---- 上层：歌曲内容（可左滑）----
            // 底色必须不透明：否则下层红色删除键会直接透上来（行原本是 transparent，
            // 把它当遮罩用就露馅了）。选中/悬停的浅色叠在这层白底上，视觉与原来一致
            Rectangle {
                id: rowContent
                width: parent.width
                height: parent.height
                // x 由 MouseArea 的 drag.target 直接驱动（C++ 侧），不写绑定也不用 Behavior
                x: 0
                radius: 8
                color: Theme.surface

                Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    color: (panel.editing && rowItem.picked) ? Theme.alpha(Theme.accent, 0.10)
                         : rowItem.current ? Theme.alpha(Theme.accent, 0.10)
                         : rowMouse.containsMouse ? Theme.alpha("#000000", 0.04)
                         : "transparent"

                    Behavior on color { ColorAnimation { duration: 100 } }
                }

                // 勾选框：仅列表管理模式下出现
                CheckBoxDot {
                    id: rowCheck
                    visible: panel.editing
                    checked: rowItem.picked
                    anchors.left: parent.left
                    anchors.leftMargin: 14
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: panel.setChecked(rowItem.file, !rowItem.picked)
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: panel.editing ? 46 : 10
                    anchors.rightMargin: 10
                    spacing: 10

                    Behavior on anchors.leftMargin { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                    // 文件类型图标：统一音符造型，按格式着色
                    FormatIcon {
                        file: rowItem.file
                        format: rowItem.format
                        size: 30
                        Layout.alignment: Qt.AlignVCenter
                    }

                    // 歌名和歌手
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 2
                        Layout.alignment: Qt.AlignVCenter

                        Text {
                            text: rowItem.title
                            color: rowItem.current ? Theme.ink : Theme.inkSoft
                            font.pixelSize: 13
                            Layout.fillWidth: true
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                        Text {
                            text: rowItem.artist
                            color: Theme.muted
                            font.pixelSize: 11
                            Layout.fillWidth: true
                            maximumLineCount: 1
                            elide: Text.ElideRight
                        }
                    }

                    // 「全部」视图里给已喜欢的行标一个心形
                    Item {
                        Layout.preferredWidth: 14
                        Layout.preferredHeight: 14
                        visible: !panel.showLiked && rowItem.liked

                        Image {
                            id: likedMark
                            anchors.fill: parent
                            source: panel.iconBase + "heart-filled.svg"
                            sourceSize: Qt.size(14, 14)
                            visible: false
                        }
                        ColorOverlay {
                            anchors.fill: likedMark
                            source: likedMark
                            color: Theme.accent
                        }
                    }

                    // 时长
                    Text {
                        text: rowItem.durationText
                        color: Theme.faint
                        font.pixelSize: 11
                        Layout.alignment: Qt.AlignVCenter
                    }
                }

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor

                    // 左滑露出删除键：交给 MouseArea 自带的 drag（C++ 侧跟手，不在 JS 里每帧算，
                    // 自己算反而会因 MouseArea 跟随移动而导致来回抖）。竖向由 ListView 接管
                    //（preventStealing 默认 false）
                    drag.target: rowContent
                    drag.axis: Drag.XAxis
                    drag.minimumX: -rowItem.revealWidth
                    drag.maximumX: 0
                    drag.threshold: 4

                    // 按下时的位置：用来区分「点击」和「左滑」
                    property real pressContentX: 0

                    onPressed: pressContentX = rowContent.x

                    onReleased: {
                        // 位移没超过阈值 = 点击，交给 onClicked 处理
                        if (Math.abs(rowContent.x - pressContentX) <= drag.threshold)
                            return
                        // 左滑：越过一半就停靠在删除键，否则回弹
                        var open = rowContent.x < -rowItem.revealWidth / 2
                        if (open) {
                            panel.swipedFile = rowItem.file
                            snapOpen.start()
                        } else {
                            panel.swipedFile = ""
                            snapBack.start()
                        }
                    }
                    onClicked: {
                        if (panel.editing) {
                            panel.setChecked(rowItem.file, !rowItem.picked)
                            return
                        }
                        // 已划开时点内容区先收起，不触发播放
                        if (rowContent.x !== 0) {
                            rowItem.closeRow()
                            panel.swipedFile = ""
                            return
                        }
                        panel.itemClicked(rowItem.file, panel.showLiked)
                    }
                }
            }

            NumberAnimation {
                id: snapOpen
                target: rowContent
                property: "x"
                to: -rowItem.revealWidth
                duration: 200
                easing.type: Easing.OutCubic
            }

            NumberAnimation {
                id: snapBack
                target: rowContent
                property: "x"
                to: 0
                duration: 240
                easing.type: Easing.OutCubic
            }
        }

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }
    }

    // 空状态
    Column {
        anchors.centerIn: parent
        spacing: 12
        visible: panel.activeCount === 0

        Text {
            text: panel.showLiked ? "还没有喜欢的歌曲" : "播放列表还是空的"
            color: Theme.muted
            font.pixelSize: 13
            anchors.horizontalCenter: parent.horizontalCenter
        }
        Text {
            visible: panel.showLiked
            text: "在播放页点歌名左侧的心形即可收藏"
            color: Theme.faint
            font.pixelSize: 11
            anchors.horizontalCenter: parent.horizontalCenter
        }
        IconButton {
            visible: !panel.showLiked
            iconSource: panel.iconBase + "plus.svg"
            iconColor: Theme.accent
            iconSize: 20
            implicitWidth: 44
            implicitHeight: 44
            tooltipText: "添加音乐"
            anchors.horizontalCenter: parent.horizontalCenter
            onClicked: panel.addMusicRequested()
        }
    }

    // ---------- 顶部区域拖动：上滑铺满 / 下滑（先收回停靠档、再隐藏） ----------
    // 这是「拖抽屉」唯一的入口（Drawer 自身的拖拽在打开时已关掉，见上方 interactive）。
    // 只覆盖把手 + 标题这一条，不和列表区域重叠，所以滑列表永远不会带动抽屉。
    MouseArea {
        id: handleArea
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        // 让开右侧图标按钮区，否则按钮点不到
        anchors.rightMargin: 140
        // 覆盖到标题栏底部：把手 + 标题这一整条都能拖（不侵入下面的分段控件）
        height: header.y + header.height

        property real pressX: 0
        property real pressY: 0

        onPressed: function(mouse) {
            pressX = mouse.x
            pressY = mouse.y
        }

        onPositionChanged: function(mouse) {
            if (!pressed) return
            var dx = mouse.x - pressX
            var dy = mouse.y - pressY
            // 横向位移不小于竖向 → 不认为是「拖抽屉」，直接忽略。
            // 否则在把手条上横向划一下也会把面板拉起来
            if (Math.abs(dy) <= Math.abs(dx)) return
            if (dy < -50 && !panel.expanded) {
                panel.expanded = true
            } else if (dy > 50 && panel.expanded) {
                panel.expanded = false
            }
        }

        onReleased: function(mouse) {
            var dx = mouse.x - pressX
            var dy = mouse.y - pressY
            if (Math.abs(dy) <= Math.abs(dx)) return
            // 已经在停靠档还继续往下拖：视为收起面板
            if (!panel.expanded && dy > 130) panel.close()
        }
    }
}
