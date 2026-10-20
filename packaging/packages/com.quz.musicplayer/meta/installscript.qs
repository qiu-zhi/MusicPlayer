// Music Player 组件脚本。
//
// 安装向导的「安装位置」页会多出一个勾选项：勾上表示卸载时连用户配置一起删。
// 配置放在 ~/.musicplayer（安装目录之外），IFW 不会主动碰它，
// 只有在安装阶段 registerPathForUninstallation 登记过，卸载流程才会清掉它。
//
// 关于「卸载时弹窗询问」：做不到 —— 往向导页里插新控件只能由组件脚本完成
// （addWizardPageItem 的第一个参数是 Component 对象），而组件脚本在卸载时不加载。
// 控制器脚本虽然在卸载时会加载（installer.isUninstaller() 为 true），
// 但它只能改已有页面的文字与按钮，不能新增控件。
// 所以把选择放在安装阶段，卸载时按记录执行。
//
// 无界面安装（--confirm-command 等）时没有向导页，勾选框拿不到，
// 这时读环境变量 MUSICPLAYER_REMOVE_CONFIG，便于脚本化安装与自动化验证。

function Component()
{
    component.loaded.connect(this, Component.prototype.addUninstallOptionCheckBox);
}

Component.prototype.createOperations = function()
{
    component.createOperations();

    if (!wantRemoveUserConfig(component.userInterface("UninstallOptionForm")))
        return;

    var dir = userConfigDir();
    if (dir !== "")
        component.registerPathForUninstallation(dir, true);
}

// 只在真正的安装流程里插入控件；维护/更新模式下没有这个页面
Component.prototype.addUninstallOptionCheckBox = function()
{
    if (installer.isInstaller())
        installer.addWizardPageItem(component, "UninstallOptionForm", QInstaller.TargetDirectory);
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
