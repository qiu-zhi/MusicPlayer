import QtQuick
import QtQuick.Dialogs

// 添加音乐的入口集合：多选歌曲 + 文件夹扫描
// 只负责「拿到路径」，不做入库、不弹提示 —— 由外部响应信号后自行处理
Item {
    id: addMusic

    // ---- 触发接口，供外部调用 ----
    function pickFiles() {
        filesDialog.open()
    }

    function pickFolder() {
        folderDialog.open()
    }

    // ---- 交互输出 ----
    signal filesPicked(var urls)          // 选中的一个或多个音频文件（OpenFiles 多选）
    signal folderPicked(url folderUrl)    // 选中文件夹（外部自行扫描 + 入库）

    // 后缀清单与「扫描 / 导入校验」共用 C++ 那一份，避免加格式时漏改这里
    readonly property string suffixFilter: {
        var list = folderScanner.audioSuffixes()
        var parts = []
        for (var i = 0; i < list.length; ++i) parts.push("*." + list[i])
        return parts.join(" ")
    }

    // ---------- 文件选择：添加歌曲（可多选，Ctrl / Shift 或框选）----------
    FileDialog {
        id: filesDialog
        title: "选择音乐文件（可多选）"
        fileMode: FileDialog.OpenFiles
        nameFilters: [
            "音频文件 (" + addMusic.suffixFilter + ")",
            "所有文件 (*)"
        ]
        onAccepted: addMusic.filesPicked(selectedFiles)
    }

    // ---------- 文件夹选择：扫描文件夹 ----------
    FolderDialog {
        id: folderDialog
        title: "选择音乐文件夹"
        onAccepted: addMusic.folderPicked(selectedFolder)
    }
}
