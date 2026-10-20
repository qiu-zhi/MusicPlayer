// Music Player 组件脚本。
//
// 安装向导里有两个勾选项（都是往「安装位置」页后插一个自定义控件）：
//   1) 是否在桌面创建快捷方式（DesktopOptionForm，默认勾选）
//   2) 卸载时是否连用户配置一起删（UninstallOptionForm，默认不勾）
//
// 往向导页里插新控件只能由组件脚本完成（addWizardPageItem 的第一个参数是
// Component 对象），所以两项都放在安装阶段选择、按记录执行。
//
// 开始菜单快捷方式不用脚本：config.xml 的 <StartMenuDir> 会让 IFW 自己建。
// 桌面快捷方式没有对应配置项，只能用 CreateShortcut operation 手工建 ——
// 它会被记入卸载日志，卸载时自动删除。
//
// 「一台机器只装一份」：QtIFW 自带的检测只看**同一个目标目录**，换个盘符
// （比如从 C 盘换到 D 盘）就能装出第二份。所以这里额外扫注册表卸载项，
// 只要机器上已有一份（不管装在哪个目录），就拦住安装并告诉用户旧的那份在哪。
//
// 无界面安装（--confirm-command 等）时没有向导页，勾选框拿不到，改读环境变量：
//   MUSICPLAYER_CREATE_DESKTOP  设 0/false 则不建桌面快捷方式（默认建）
//   MUSICPLAYER_REMOVE_CONFIG   设 1/true 则卸载时连 ~/.musicplayer 一起删（默认不删）
//   MUSICPLAYER_FORCE_INSTALL   设 1 可跳过「已安装」检查（仅调试用）

function Component()
{
    // 先连卸载选项、后连桌面选项：后 connect 的会插在更靠近「安装位置」页的位置，
    // 于是向导里的顺序是 安装位置 → 桌面快捷方式 → 卸载选项
    component.loaded.connect(this, Component.prototype.addUninstallOptionCheckBox);
    component.loaded.connect(this, Component.prototype.addDesktopOptionCheckBox);
}

// 「安装位置」页点下一步时拦一道：机器上已有一份就别让继续
Component.prototype.targetDirectoryPageClicked = function()
{
    if (installer.environmentVariable("MUSICPLAYER_FORCE_INSTALL") === "1")
        return true;

    var existing = findExistingInstall();
    if (existing === "")
        return true;

    // 同一目录不算冲突（那种情况 IFW 自己会走更新流程）
    if (samePath(existing, installer.value("TargetDir")))
        return true;

    QMessageBox.critical("无法安装 Music Player",
        "检测到本机已经安装了一份 Music Player：\n\n    " + existing +
        "\n\n一次只能安装一份。请先卸载旧版本" +
        "\n（控制面板 → 程序和功能 → Music Player，或运行该目录下的 MusicPlayerMaintenance.exe），" +
        "\n再重新安装。");
    return false;   // 阻止进入下一步
}

Component.prototype.createOperations = function()
{
    // 无人值守安装也走这里，同样查一遍（防止脚本化安装绕过上面的页面回调）
    if (installer.environmentVariable("MUSICPLAYER_FORCE_INSTALL") !== "1") {
        var existing = findExistingInstall();
        if (existing !== "" && !samePath(existing, installer.value("TargetDir")))
            throw new Error("已安装到 " + existing + "，请先卸载旧版本");
    }

    component.createOperations();

    if (wantCreateDesktopShortcut(component.userInterface("DesktopOptionForm"))) {
        var desktop = installer.value("DesktopDir");
        // 目标用 @TargetDir@ 让 IFW 自己展开；快捷方式名与开始菜单里保持一致
        if (desktop)
            component.addOperation("CreateShortcut",
                                   "@TargetDir@/MusicPlayer.exe",
                                   String(desktop).replace(/\\/g, "/") + "/Music Player.lnk");
    }

    if (!wantRemoveUserConfig(component.userInterface("UninstallOptionForm")))
        return;

    var dir = userConfigDir();
    if (dir !== "")
        component.registerPathForUninstallation(dir, true);
}

// 只在真正的安装流程里插入控件；维护/更新模式下没有这些页面
Component.prototype.addUninstallOptionCheckBox = function()
{
    if (installer.isInstaller())
        installer.addWizardPageItem(component, "UninstallOptionForm", QInstaller.TargetDirectory);
}

Component.prototype.addDesktopOptionCheckBox = function()
{
    if (installer.isInstaller())
        installer.addWizardPageItem(component, "DesktopOptionForm", QInstaller.TargetDirectory);
}

// 扫注册表卸载项，找 MusicPlayerMaintenance.exe 的所在目录；没找到返回 ""
// 匹配 UninstallString 而不是 DisplayName：不依赖系统语言，也不会被同名软件误用
//
// ⚠️ 这里只用 reg：QtIFW 脚本环境**没有 QFile/QDir**（试过，报
//    ReferenceError: QFile is not defined），所以没法做纯脚本的文件探测。
//    reg 是 Windows 自带组件，正常机器上一定在；万一被安全软件拦（执行返回非 0），
//    这里按"没装过"放行 —— 宁可漏拦也不误拦，误拦会把用户挡在门外。
function findExistingInstall()
{
    var roots = [
        "HKCU\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall",
        "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall"
    ];
    for (var i = 0; i < roots.length; i++) {
        var r = installer.execute("reg",
            ["query", roots[i], "/s", "/f", "MusicPlayerMaintenance.exe", "/d"]);
        if (r[0] !== 0) {
            console.log("MusicPlayer: reg query 失败(rc=" + r[0] + ")，跳过单实例检测");
            continue;
        }
        // 输出里形如：  UninstallString  REG_SZ  "D:\...\MusicPlayerMaintenance.exe" --start-uninstaller
        var m = r[1].match(/UninstallString\s+REG_SZ\s+"?([^"\r\n]*?MusicPlayerMaintenance\.exe)/i);
        if (m)
            return m[1].replace(/"/g, "");
    }
    return "";
}

function samePath(a, b)
{
    if (!a || !b)
        return false;
    var norm = function(s) {
        return String(s).replace(/\\/g, "/").replace(/\/+$/, "").toLowerCase();
    };
    return norm(a) === norm(b);
}

// 有向导时看勾选框；无向导（脚本化安装）看环境变量，默认创建
function wantCreateDesktopShortcut(form)
{
    if (form)
        return form.CreateDesktopShortcutCheckBox.checked;

    var env = installer.environmentVariable("MUSICPLAYER_CREATE_DESKTOP");
    return !(env === "0" || env === "false");
}

function wantRemoveUserConfig(form)
{
    if (form)
        return form.RemoveConfigCheckBox.checked;

    var env = installer.environmentVariable("MUSICPLAYER_REMOVE_CONFIG");
    return env === "1" || env === "true";
}

// 用户配置目录：优先用 IFW 的 HomeDir，拿不到再退回环境变量
function userConfigDir()
{
    var home = installer.value("HomeDir");
    if (!home)
        home = installer.environmentVariable("USERPROFILE");
    if (!home)
        home = installer.environmentVariable("HOME");
    if (!home)
        return "";
    return String(home).replace(/\\/g, "/") + "/.musicplayer";
}
