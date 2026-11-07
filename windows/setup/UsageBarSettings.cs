using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class UsageBarSettings : Form
{
    private readonly string installed = CodexUsageBar.InstalledVersion();
    private readonly CheckBox autoCheck = new CheckBox { Text = "启动时自动检查 Windows 版更新", AutoSize = true };
    private readonly CheckBox shortQuota = new CheckBox { Text = "短周期剩余额度（通常为 5 小时）", AutoSize = true };
    private readonly CheckBox weeklyQuota = new CheckBox { Text = "每周剩余额度", AutoSize = true };
    private readonly CheckBox resetTimes = new CheckBox { Text = "额度重置时间与倒计时", AutoSize = true };
    private readonly CheckBox resetCards = new CheckBox { Text = "重置卡数量和到期明细", AutoSize = true };
    private readonly CheckBox expandCards = new CheckBox { Text = "默认展开卡片明细", AutoSize = true, Margin = new Padding(22, 3, 3, 3) };
    private readonly Button check = ActionButton("检查更新");
    private readonly Button download = ActionButton("下载安装");
    private readonly Label updateStatus = TextLabel("可以手动检查 GitHub 上的 Windows 版本。");
    private readonly Label saveStatus = TextLabel("显示设置在完全退出并重新打开 Codex UsageBar 后生效。");
    private CodexUsageBar.Update available;
    private bool downloading;

    internal UsageBarSettings()
    {
        Text = "Codex UsageBar 设置";
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Font;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(16);

        var title = TextLabel("Codex UsageBar");
        title.Font = new Font(Font.FontFamily, 16, FontStyle.Bold);
        var updates = Section("在线更新", TextLabel("当前版本  v" + installed),
            Row(check, download), updateStatus, autoCheck);
        var display = Section("侧栏显示", shortQuota, weeklyQuota, resetTimes, resetCards, expandCards);
        var restore = ActionButton("恢复默认");
        var save = ActionButton("保存设置");
        var body = Column(title, updates, display, saveStatus, Row(save, restore));
        body.Dock = DockStyle.Fill;
        Controls.Add(body);

        download.Enabled = false;
        check.Click += async (sender, args) => await CheckUpdate();
        download.Click += async (sender, args) => await DownloadUpdate();
        shortQuota.CheckedChanged += (sender, args) => UpdateDisplayControls();
        weeklyQuota.CheckedChanged += (sender, args) => UpdateDisplayControls();
        resetCards.CheckedChanged += (sender, args) => UpdateDisplayControls();
        restore.Click += (sender, args) =>
        {
            SetControls(new CodexUsageBar.Preferences());
            saveStatus.Text = "已恢复默认选项，点击「保存设置」应用。";
        };
        save.Click += (sender, args) => Save();
        SetControls(CodexUsageBar.ReadPreferences());
    }

    private static Label TextLabel(string text)
    {
        return new Label { Text = text, AutoSize = true, MaximumSize = new Size(420, 0), Margin = new Padding(3, 4, 3, 4) };
    }

    private static Button ActionButton(string text)
    {
        return new Button { Text = text, AutoSize = true, MinimumSize = new Size(86, 30) };
    }

    private static FlowLayoutPanel Row(params Control[] items)
    {
        var panel = new FlowLayoutPanel { AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, WrapContents = false };
        panel.Controls.AddRange(items);
        return panel;
    }

    private static FlowLayoutPanel Column(params Control[] items)
    {
        var panel = Row(items);
        panel.FlowDirection = FlowDirection.TopDown;
        return panel;
    }

    private static GroupBox Section(string title, params Control[] items)
    {
        var section = new GroupBox
        {
            Text = title, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink,
            Padding = new Padding(12, 9, 12, 9), MinimumSize = new Size(445, 0)
        };
        var body = Column(items);
        body.Dock = DockStyle.Fill;
        section.Controls.Add(body);
        return section;
    }

    private void SetControls(CodexUsageBar.Preferences preferences)
    {
        autoCheck.Checked = preferences.autoCheckUpdates;
        shortQuota.Checked = preferences.showShort;
        weeklyQuota.Checked = preferences.showWeekly;
        resetTimes.Checked = preferences.showResetTimes;
        resetCards.Checked = preferences.showResetCredits;
        expandCards.Checked = preferences.expandCards;
        UpdateDisplayControls();
    }

    private void UpdateDisplayControls()
    {
        resetTimes.Enabled = shortQuota.Checked || weeklyQuota.Checked;
        expandCards.Enabled = resetCards.Checked;
    }

    private void Save()
    {
        try
        {
            CodexUsageBar.SavePreferences(new CodexUsageBar.Preferences
            {
                autoCheckUpdates = autoCheck.Checked, showShort = shortQuota.Checked, showWeekly = weeklyQuota.Checked,
                showResetTimes = resetTimes.Checked, showResetCredits = resetCards.Checked, expandCards = expandCards.Checked
            });
            saveStatus.Text = "已保存。完全退出并重新打开 Codex UsageBar 后应用显示设置。";
        }
        catch (Exception error)
        {
            MessageBox.Show(this, "保存设置失败。\n\n" + error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }

    private async Task CheckUpdate()
    {
        check.Enabled = download.Enabled = false;
        available = null;
        updateStatus.Text = "正在检查更新…";
        try
        {
            available = await Task.Run(() => CodexUsageBar.WithUpdateLock(() => CodexUsageBar.FindUpdate(installed)));
            updateStatus.Text = available == null ? "已经是最新版本。" : "发现新版 v" + available.version + "。";
        }
        catch (Exception error)
        {
            updateStatus.Text = "暂时无法检查更新。 " + error.Message;
        }
        finally
        {
            check.Enabled = true;
            download.Enabled = available != null;
        }
    }

    private async Task DownloadUpdate()
    {
        if (available == null) return;
        var choice = MessageBox.Show(this, "下载 v" + available.version +
            " 并打开安装向导？安装前请保存工作并退出 Codex UsageBar。",
            Text, MessageBoxButtons.YesNo, MessageBoxIcon.Information, MessageBoxDefaultButton.Button2);
        if (choice != DialogResult.Yes) return;
        var update = available;
        check.Enabled = download.Enabled = false;
        downloading = true;
        updateStatus.Text = "正在下载并校验安装包…";
        try
        {
            await Task.Run(() => CodexUsageBar.WithUpdateLock(() =>
            {
                CodexUsageBar.StartUpdate(update, installed);
                return true;
            }));
            downloading = false;
            Close();
        }
        catch (Exception error)
        {
            downloading = false;
            updateStatus.Text = "下载安装包失败。 " + error.Message;
            check.Enabled = download.Enabled = true;
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (downloading && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
        base.OnFormClosing(e);
    }
}
