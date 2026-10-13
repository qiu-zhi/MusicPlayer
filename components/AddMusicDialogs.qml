import QtQuick
import QtQuick.Dialogs

// 添加音乐的入口集合：单曲选择 + 文件夹扫描
// 只负责「拿到路径」，不做入库、不弹提示 —— 由外部响应信号后自行处理
Item {
    id: addMusic

    // ---- 触发接口，供外部调用 ----
    function pickSingleFile() {
        singleFileDialog.open()
    }

    function pickFolder() {
        folderDialog.open()
    }

    // ---- 交互输出 ----
    signal filePicked(url fileUrl)        // 选中单个音频文件
    signal folderPicked(url folderUrl)    // 选中文件夹（外部自行扫描 + 入库）

    // ---------- 文件选择：添加单曲 ----------
    FileDialog {
        id: singleFileDialog
        title: "选择音乐文件"
        fileMode: FileDialog.OpenFile
        nameFilters: [
            "音频文件 (*.mp3 *.flac *.wav *.m4a *.aac *.ogg *.wma *.ape *.opus)",
            "所有文件 (*)"
        ]
        onAccepted: addMusic.filePicked(selectedFile)
    }

    // ---------- 文件夹选择：扫描文件夹 ----------
    FolderDialog {
        id: folderDialog
        title: "选择音乐文件夹"
        onAccepted: addMusic.folderPicked(selectedFolder)
    }
}
