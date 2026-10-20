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
// 无界面安装（--confirm-command 等）时没有向导页，勾选框拿不到，改读环境变量：
//   MUSICPLAYER_CREATE_DESKTOP  设 0/false 则不建桌面快捷方式（默认建）
//   MUSICPLAYER_REMOVE_CONFIG   设 1/true 则卸载时连 ~/.musicplayer 一起删（默认不删）

function Component()
{
    // 先连卸载选项、后连桌面选项：后 connect 的会插在更靠近「安装位置」页的位置，
    // 于是向导里的顺序是 安装位置 → 桌面快捷方式 → 卸载选项
    component.loaded.connect(this, Component.prototype.addUninstallOptionCheckBox);
    component.loaded.connect(this, Component.prototype.addDesktopOptionCheckBox);
}

Component.prototype.createOperations = function()
{
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
