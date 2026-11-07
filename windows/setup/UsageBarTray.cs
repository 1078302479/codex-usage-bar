using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

internal sealed class UsageBarTray : ApplicationContext
{
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    private readonly NotifyIcon icon;
    private readonly ContextMenuStrip menu = new ContextMenuStrip();
    private readonly System.Windows.Forms.Timer signals = new System.Windows.Forms.Timer { Interval = 200 };
    private readonly Icon artwork;
    private UsageBarSettings settings;
    private bool restarting;
    private bool shuttingDown;
    private bool exitRequested;

    private UsageBarTray(EventWaitHandle show, EventWaitHandle quit)
    {
        artwork = Icon.ExtractAssociatedIcon(Application.ExecutablePath);
        icon = new NotifyIcon { Text = "Codex UsageBar", Icon = artwork ?? SystemIcons.Application, ContextMenuStrip = menu };
        menu.Items.Add("打开设置", null, (sender, args) => ShowSettings());
        menu.Items.Add("打开 Codex", null, (sender, args) =>
        {
            Process.Start(new ProcessStartInfo(Application.ExecutablePath) { UseShellExecute = true });
        });
        menu.Items.Add("重启 Codex", null, async (sender, args) =>
        {
            if (restarting) return;
            restarting = true;
            try { await CodexUsageBar.ConfirmRestart(settings != null && !settings.IsDisposed ? settings : null); }
            finally { restarting = false; }
        });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出托盘", null, (sender, args) => RequestExit());
        icon.MouseClick += (sender, args) =>
        {
            if (args.Button == MouseButtons.Left) ShowSettings();
        };
        signals.Tick += (sender, args) =>
        {
            if (quit.WaitOne(0)) exitRequested = true;
            if (exitRequested) RequestExit();
            else if (show.WaitOne(0)) ShowSettings();
        };
        icon.Visible = true;
        signals.Start();
    }

    private static string InstanceName(string root)
    {
        string full = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar).ToUpperInvariant();
        using (var sha = SHA256.Create())
            return @"Local\CodexUsageBar-" + BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(full))).Replace("-", "");
    }

    internal static void Run(string root, bool showSettings)
    {
        string name = InstanceName(root);
        using (var show = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-show"))
        using (var quit = new EventWaitHandle(false, EventResetMode.AutoReset, name + "-quit"))
        using (var instance = new Mutex(false, name))
        {
            bool owner;
            try { owner = instance.WaitOne(0); }
            catch (AbandonedMutexException) { owner = true; }
            if (!owner)
            {
                if (showSettings) show.Set();
                return;
            }
            try
            {
                using (var tray = new UsageBarTray(show, quit))
                {
                    if (showSettings) show.Set();
                    Application.Run(tray);
                }
            }
            finally { instance.ReleaseMutex(); }
        }
    }

    internal static void SignalExit(string root)
    {
        EventWaitHandle quit;
        if (EventWaitHandle.TryOpenExisting(InstanceName(root) + "-quit", out quit))
        {
            using (quit) quit.Set();
        }
    }

    private void ShowSettings()
    {
        if (settings == null || settings.IsDisposed) settings = new UsageBarSettings();
        if (!settings.Visible) settings.Show();
        if (settings.WindowState == FormWindowState.Minimized) settings.WindowState = FormWindowState.Normal;
        const int Show = 5;
        ShowWindow(settings.Handle, Show);
        settings.Activate();
    }

    private void RequestExit()
    {
        if (shuttingDown || restarting) return;
        if (settings != null && !settings.IsDisposed)
        {
            settings.Close();
            if (!settings.IsDisposed) return;
        }
        shuttingDown = true;
        ExitThread();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            signals.Dispose();
            icon.Visible = false;
            icon.Dispose();
            menu.Dispose();
            if (artwork != null) artwork.Dispose();
        }
        base.Dispose(disposing);
    }
}
