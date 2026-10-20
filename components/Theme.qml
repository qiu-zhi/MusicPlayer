pragma Singleton
import QtQuick

// 全局配色。界面里不再写死颜色字面量，改配色只改这一处。
// 用法：Theme.ink / Theme.alpha(Theme.accent, 0.1)
QtObject {
    readonly property color bg: "#E3E6E9"        // 页面底色
    readonly property color surface: "#FFFFFF"   // 卡片底 / 反白文字与图标
    readonly property color ink: "#17181A"       // 主文字、主图标
    readonly property color inkSoft: "#4A4E54"   // 列表行文字（比主文字浅）
    readonly property color muted: "#8A8D92"     // 次要文字
    readonly property color faint: "#B9BDC2"     // 三级文字（时长等）
    readonly property color disabled: "#C2C7CC"  // 禁用态图标
    readonly property color accent: "#F3693A"    // 品牌橙
    readonly property color accentHover: "#E85C2E"  // 主按钮悬停
    readonly property color accentPress: "#D55228"  // 主按钮按下
    readonly property color danger: "#E4573A"    // 删除 / 危险操作
    readonly property color hairline: "#E4E6E9"  // 描边 / 分隔线
    readonly property color edge: "#E1E3E7"      // 面板描边（略深）
    readonly property color track: "#D8DADD"     // 进度条轨道 / 把手
    readonly property color fill: "#F0F1F3"      // 分段控件底

    // 同一个颜色加透明度：阴影、遮罩、悬停底色都用它，避免出现一堆 #1AF3693A
    function alpha(c, a) {
        return Qt.rgba(c.r, c.g, c.b, a)
    }
}
