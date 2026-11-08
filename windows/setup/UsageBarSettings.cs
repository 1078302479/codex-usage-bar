using System;
using System.Drawing;
using System.Threading.Tasks;
using System.Windows.Forms;

internal sealed class UsageBarSettings : Form
{
    private static readonly Color Canvas = SystemInformation.HighContrast ? SystemColors.Window : Color.FromArgb(244, 247, 252);
    private static readonly Color Card = SystemColors.Window;
    private static readonly Color Ink = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(24, 38, 61);
    private static readonly Color Muted = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(75, 94, 122);
    private static readonly Color Accent = SystemInformation.HighContrast ? SystemColors.Highlight : Color.FromArgb(31, 81, 183);
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
    private readonly Button recheckCompatibility = ActionButton("重新检测");
    private readonly Label compatibilityStatus = TextLabel("正在检测本机 Codex…");
    private readonly Label saveStatus = TextLabel("保存后可一键重启 Codex 以应用显示设置。");
    private readonly Button save = ActionButton("保存设置");
    private readonly Button restart = ActionButton("重启 Codex");
    private CodexUsageBar.Update available;
    private bool downloading;
    private bool saving;

    internal UsageBarSettings()
    {
#if USAGEBAR_SMOKE
        Text = "Codex UsageBar 设置（隔离测试）";
#else
        Text = "Codex UsageBar 设置";
#endif
        Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        Font = new Font("Segoe UI", 10);
        BackColor = Canvas;
        ForeColor = Ink;
        AutoScaleMode = AutoScaleMode.Font;
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(22, 18, 22, 16);

        var eyebrow = TextLabel("CODEX USAGEBAR   /   WINDOWS");
        eyebrow.ForeColor = Accent;
        eyebrow.Font = new Font(Font.FontFamily, 9, FontStyle.Bold);
        var title = TextLabel("偏好设置");
        title.ForeColor = Ink;
        title.Font = new Font(Font.FontFamily, 21, FontStyle.Bold);
        var version = TextLabel("v" + installed);
        version.BackColor = Card;
        version.ForeColor = Accent;
        version.Padding = new Padding(9, 4, 9, 4);
        version.Margin = new Padding(12, 12, 0, 0);
        var description = TextLabel("自定义 Codex 侧栏，或检查 Windows 版更新。");
        description.Margin = new Padding(3, 1, 3, 12);
        var updates = Section("软件更新", "管理 Windows 版更新提醒。",
            autoCheck, Row(check, download), updateStatus);
        var display = Section("侧栏显示", "选择侧栏和悬停弹框中显示的内容。",
            shortQuota, weeklyQuota, resetTimes, resetCards, expandCards);
        var compatibility = Section("Codex 兼容性", "离线检查本机 Microsoft Store 版 Codex。",
            compatibilityStatus, recheckCompatibility);
        var restore = ActionButton("恢复默认");
        save.BackColor = Accent;
        save.ForeColor = SystemInformation.HighContrast ? SystemColors.HighlightText : Color.White;
        save.FlatAppearance.BorderSize = 0;
        var body = Column(eyebrow, Row(title, version), description, display, updates, compatibility, saveStatus, Row(save, restart, restore));
        body.Location = new Point(Padding.Left, Padding.Top);
        AutoScroll = true;
        MaximumSize = new Size(0, Screen.FromPoint(Cursor.Position).WorkingArea.Height);
        Controls.Add(body);

        download.Enabled = false;
        Shown += async (sender, args) => await RefreshCompatibility();
        recheckCompatibility.Click += async (sender, args) => await RefreshCompatibility();
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
        save.Click += async (sender, args) => await Save();
        restart.Click += async (sender, args) =>
        {
            if (saving || downloading) return;
            SetSaving(true);
            try { await RestartAndReport(); }
            finally { SetSaving(false); }
        };
        SetControls(CodexUsageBar.ReadPreferences());
    }

    private static Label TextLabel(string text)
    {
        return new Label { Text = text, AutoSize = true, ForeColor = Muted, MaximumSize = new Size(466, 0), Margin = new Padding(3, 4, 3, 4) };
    }

    private static Button ActionButton(string text)
    {
        var button = new Button
        {
            Text = text, AutoSize = true, MinimumSize = new Size(94, 34), Padding = new Padding(8, 2, 8, 2),
            FlatStyle = FlatStyle.Flat, BackColor = Card, ForeColor = Ink, UseVisualStyleBackColor = false,
        };
        button.FlatAppearance.BorderColor = SystemInformation.HighContrast ? SystemColors.WindowText : Color.FromArgb(202, 214, 233);
        return button;
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

    private FlowLayoutPanel Section(string title, string description, params Control[] items)
    {
        var heading = TextLabel(title);
        heading.ForeColor = Ink;
        heading.Font = new Font(Font.FontFamily, 12, FontStyle.Bold);
        var section = Column(heading, TextLabel(description));
        section.BackColor = Card;
        section.Padding = new Padding(14, 10, 14, 10);
        section.MinimumSize = new Size(475, 0);
        section.Margin = new Padding(0, 0, 0, 10);
        section.Controls.AddRange(items);
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

    private async Task Save()
    {
        if (saving || downloading) return;
        bool saved = false;
        SetSaving(true);
        try
        {
            CodexUsageBar.SavePreferences(new CodexUsageBar.Preferences
            {
                autoCheckUpdates = autoCheck.Checked, showShort = shortQuota.Checked, showWeekly = weeklyQuota.Checked,
                showResetTimes = resetTimes.Checked, showResetCredits = resetCards.Checked, expandCards = expandCards.Checked
            });
            saved = true;
            saveStatus.Text = "设置已保存。";
            if (await Task.Run(() => CodexUsageBar.DisplayChangesPending()))
            {
                saveStatus.Text = "设置已保存，等待重启 Codex。";
                await RestartAndReport();
            }
        }
        catch (Exception error)
        {
            var message = saved ? "设置已保存，暂时无法确认是否需要重启。" : "保存设置失败。";
            MessageBox.Show(this, message + "\n\n" + error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
        finally
        {
            SetSaving(false);
        }
    }

    private void SetSaving(bool busy)
    {
        saving = busy;
        save.Enabled = restart.Enabled = !busy;
    }

    private async Task RestartAndReport()
    {
        if (!await CodexUsageBar.ConfirmRestart(this)) return;
        try
        {
            saveStatus.Text = await Task.Run(() => CodexUsageBar.DisplayChangesPending())
                ? "Codex 已打开，显示设置仍等待应用。" : "Codex 已重启，显示设置已生效。";
        }
        catch (Exception)
        {
            saveStatus.Text = "Codex 已重启，暂时无法确认显示设置状态。";
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
            if (IsDisposed) return;
            updateStatus.Text = available == null ? "已经是最新版本。" : "发现新版 v" + available.version + "。";
        }
        catch (Exception error)
        {
            if (!IsDisposed) updateStatus.Text = "暂时无法检查更新。 " + error.Message;
        }
        finally
        {
            if (!IsDisposed)
            {
                check.Enabled = true;
                download.Enabled = available != null;
            }
        }
    }

    private async Task RefreshCompatibility()
    {
        recheckCompatibility.Enabled = false;
        compatibilityStatus.Text = "正在检测本机 Codex…";
        try
        {
            var report = await Task.Run(() => CodexUsageBar.CheckCompatibility());
            if (IsDisposed) return;
            if (report.status == "missing")
            {
                compatibilityStatus.Text = "未检测到 Microsoft Store 版 Codex（x64）。";
                return;
            }
            string version = report.packageVersion == null ? "" : "商店版本 " + report.packageVersion + "\n";
            if (report.clientVersion != null) version += "客户端构建 " + report.clientVersion + "\n";
            if (report.status == "compatible" || report.status == "partial")
            {
                compatibilityStatus.Text = version + (report.status == "compatible" ? "兼容" : "部分兼容") + " · 侧栏额度支持\n"
                    + "重置卡明细" + (report.resetCredits ? "支持" : "未适配")
                    + " · 置顶窗口" + (report.pin ? "支持" : "未适配");
            }
            else
            {
                string status = report.status == "incompatible" ? "不兼容，需要适配。" : "暂时无法完成检测。";
                compatibilityStatus.Text = version + status + (String.IsNullOrEmpty(report.reason) ? "" : "\n" + report.reason);
            }
        }
        finally
        {
            if (!IsDisposed) recheckCompatibility.Enabled = true;
        }
    }

    private async Task DownloadUpdate()
    {
        if (available == null || saving || downloading) return;
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
        if ((downloading || saving) && e.CloseReason == CloseReason.UserClosing) e.Cancel = true;
        base.OnFormClosing(e);
    }
}
