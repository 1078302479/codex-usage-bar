using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

[assembly: System.Reflection.AssemblyTitle("Codex UsageBar")]
[assembly: System.Reflection.AssemblyDescription("Windows launcher for the Codex UsageBar sidebar")]
[assembly: System.Reflection.AssemblyProduct("Codex UsageBar for Windows")]

internal static class CodexUsageBar
{
    private const string StoreFamily = "OpenAI.Codex_2p2nqsd0c76g0";
    private const string SetupName = "CodexUsageBar-Windows-x64-Setup.exe";
    private const string Title = "Codex UsageBar";
    private const string ExitMessage = "Save your work and exit Codex from the File menu or system tray, then try again.";
    private static readonly string Root = AppDomain.CurrentDomain.BaseDirectory;
    private static readonly string Local = Path.Combine(Root, ".local");
    private static readonly string Client = Path.Combine(Local, "windows-sidebar-client");
    private static readonly string ClientExe = Path.Combine(Client, "ChatGPT.exe");
    private static readonly string VersionFile = Path.Combine(Local, "windows-sidebar-version.txt");
    private static readonly string PreferencesFile = Path.Combine(Local, "display-settings.json");
    private const string UpdateMutex = @"Local\CodexUsageBarWindowsUpdate";

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagesByPackageFamily(string family, ref int count,
        [Out] IntPtr[] names, ref int length, IntPtr buffer);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetPackagePathByFullName(string name, ref int length, StringBuilder path);

    [STAThread]
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length == 0)
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                WithLock(Launch);
                if (!ReadPreferences().autoCheckUpdates || !CheckForUpdate()) UsageBarTray.Run(Root, false);
            }
            else if (args.Length == 1 && (args[0] == "settings" || args[0] == "tray"))
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                UsageBarTray.Run(Root, args[0] == "settings");
            }
            else if (args[0] == "install" && args.Length == 2)
            {
                WithLock(() => RunNode("packaged-client.mjs", "install", FindStoreClient()));
                File.WriteAllText(args[1], "Store client copy prepared and verified." + Environment.NewLine);
            }
            else if (args[0] == "verify") RunNode("packaged-client.mjs", "verify");
            else if (args[0] == "check-client" && args.Length == 2)
            {
                AssertClosed(Path.Combine(args[1], ".local", "windows-sidebar-client"));
                AssertSettingsClosed(args[1]);
            }
            else if (args[0] == "check-path" && args.Length == 2) AssertClosed(args[1]);
            else if (args[0] == "remove")
            {
                WithLock(() => RunNode("packaged-client.mjs", "remove"));
                try { Directory.Delete(Local); } catch (IOException) { }
            }
            else return 1;
            return 0;
        }
        catch (Exception error)
        {
            if (args.Length == 0 || args[0] == "settings" || args[0] == "tray")
                MessageBox.Show(error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (args.Length == 2 && args[0] == "install")
            {
                try { File.WriteAllText(args[1], error.Message + Environment.NewLine); } catch (IOException) { }
            }
            return 1;
        }
    }

    private static string FindStoreClient()
    {
        string version;
        string app = FindStoreClient(out version);
        if (app == null) throw new InvalidOperationException("A supported Microsoft Store Codex installation was not found.");
        return app;
    }

    private static string FindStoreClient(out string version)
    {
        const int InsufficientBuffer = 122;
        version = null;
        int count = 0, length = 0;
        int result = GetPackagesByPackageFamily(StoreFamily, ref count, null, ref length, IntPtr.Zero);
        if (result == 0 && count == 0) return null;
        if (result != InsufficientBuffer)
            throw new InvalidOperationException("Could not read the Microsoft Store package registration.");
        var names = new IntPtr[count];
        IntPtr buffer = Marshal.AllocHGlobal(length * sizeof(char));
        try
        {
            if (GetPackagesByPackageFamily(StoreFamily, ref count, names, ref length, buffer) != 0)
                throw new InvalidOperationException("Could not read the Microsoft Store package registration.");
            var candidates = names.Take(count).Select(pointer => Marshal.PtrToStringUni(pointer)).Where(name => name != null)
                .Select(name => new { Name = name, Fields = name.Split('_') })
                .Where(package => package.Fields.Length == 5 && package.Fields[2] == "x64")
                .OrderByDescending(package => Version.Parse(package.Fields[1]));
            foreach (var package in candidates)
            {
                if (version == null) version = package.Fields[1];
                int pathLength = 0;
                if (GetPackagePathByFullName(package.Name, ref pathLength, null) != InsufficientBuffer) continue;
                var path = new StringBuilder(pathLength);
                if (GetPackagePathByFullName(package.Name, ref pathLength, path) != 0) continue;
                string app = Path.Combine(path.ToString(), "app");
                if (File.Exists(Path.Combine(app, "ChatGPT.exe")) && File.Exists(Path.Combine(app, "resources", "app.asar")))
                {
                    version = package.Fields[1];
                    return app;
                }
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        return null;
    }

    private static void WithLock(Action action)
    {
        using (AcquireClientLock()) action();
    }

    private static FileStream AcquireClientLock()
    {
        Directory.CreateDirectory(Local);
        string path = Path.Combine(Local, "windows-sidebar-launch.lock");
        return new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 4096, FileOptions.DeleteOnClose);
    }

    private static string ProcessPath(Process process)
    {
        try { return process.MainModule.FileName; }
        catch (System.ComponentModel.Win32Exception) { return null; }
        catch (InvalidOperationException) { return null; }
    }

    private static void AssertClosed(string directory)
    {
        string prefix = Path.GetFullPath(directory).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        foreach (Process process in Process.GetProcesses())
        {
            using (process)
            {
                string path = ProcessPath(process);
                if (path != null && path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(ExitMessage);
            }
        }
    }

    private static void AssertSettingsClosed(string directory)
    {
        string launcher = Path.Combine(directory, "CodexUsageBar.exe");
        using (var self = Process.GetCurrentProcess())
        {
            foreach (Process process in Process.GetProcessesByName("CodexUsageBar"))
            {
                using (process)
                {
                    if (process.Id != self.Id && String.Equals(ProcessPath(process), launcher, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("Close the Codex UsageBar Settings window, then try again.");
                }
            }
        }
    }

    private static bool HasRunningClient()
    {
        var clients = Process.GetProcessesByName("ChatGPT");
        try
        {
            foreach (Process process in clients)
            {
                if (!String.Equals(ProcessPath(process), ClientExe, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("当前正在运行另一套 Codex。请从正在使用的 UsageBar 版本打开设置，或先退出另一套 Codex。");
            }
            return clients.Length != 0;
        }
        finally { foreach (Process process in clients) process.Dispose(); }
    }

    private static void Launch()
    {
        if (!HasRunningClient() && DisplayChangesPending())
            ApplyDisplaySettings();
        RunNode("packaged-client.mjs", "verify");
        Process.Start(new ProcessStartInfo(ClientExe) { WorkingDirectory = Client, UseShellExecute = true });
    }

    internal static bool DisplayChangesPending()
    {
        return RunNode("packaged-client.mjs", "display-pending").Trim() == "true";
    }

    private static Process[] RunningCopy()
    {
        return Process.GetProcessesByName("ChatGPT").Where(process =>
        {
            if (String.Equals(ProcessPath(process), ClientExe, StringComparison.OrdinalIgnoreCase)) return true;
            process.Dispose();
            return false;
        }).ToArray();
    }

    private static void WaitForCopy(bool opening)
    {
        var timer = Stopwatch.StartNew();
        while (timer.Elapsed < TimeSpan.FromSeconds(30))
        {
            var copy = RunningCopy();
            try
            {
                if (opening ? copy.Any(process => process.MainWindowHandle != IntPtr.Zero) : copy.Length == 0) return;
            }
            finally { foreach (var process in copy) process.Dispose(); }
            Thread.Sleep(300);
        }
        throw new InvalidOperationException(opening ? "暂时未看到新版窗口，请从托盘重新打开 Codex。" : "Codex 仍在退出，请稍后重试。");
    }

    internal static async Task<bool> ConfirmRestart(IWin32Window owner)
    {
        try
        {
            HasRunningClient();
            var choice = MessageBox.Show(owner, "重启会暂时关闭 Codex UsageBar。请先保存当前工作，确认后会自动重新打开。",
                "重新启动 Codex", MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2);
            if (choice != DialogResult.Yes) return false;
            using (AcquireClientLock())
            {
                HasRunningClient();
                await Task.Run(() =>
                {
                    var copy = RunningCopy();
                    try
                    {
                        var main = copy.FirstOrDefault(process => process.MainWindowHandle != IntPtr.Zero)
                            ?? copy.OrderBy(process => process.StartTime).FirstOrDefault();
                        if (main != null) ClientRestart.Request(main);
                    }
                    finally { foreach (var process in copy) process.Dispose(); }
                    WaitForCopy(false);
                });
                Launch();
                await Task.Run(() => WaitForCopy(true));
            }
            return true;
        }
        catch (Exception error)
        {
            MessageBox.Show(owner, "重启未完成，已保存的设置可在下次打开时应用。\n\n" + error.Message,
                Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }

    private static void ApplyDisplaySettings()
    {
        using (var progress = new Form())
        {
            progress.Text = Title;
            progress.StartPosition = FormStartPosition.CenterScreen;
            progress.FormBorderStyle = FormBorderStyle.FixedDialog;
            progress.ControlBox = false;
            progress.AutoSize = true;
            progress.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            var body = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, Padding = new Padding(20) };
            body.Controls.Add(new Label { Text = "正在应用侧栏显示设置…", AutoSize = true });
            body.Controls.Add(new ProgressBar { Style = ProgressBarStyle.Marquee, Width = 290 });
            progress.Controls.Add(body);
            bool finished = false;
            progress.FormClosing += (sender, args) =>
            {
                if (!finished && args.CloseReason == CloseReason.UserClosing) args.Cancel = true;
            };
            progress.Shown += async (sender, args) =>
            {
                try { await Task.Run(() => RunNode("packaged-client.mjs", "install", FindStoreClient())); }
                catch (Exception error)
                {
                    MessageBox.Show(progress, "显示设置暂未应用，将使用之前的设置。\n\n" + error.Message,
                        Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
                finally
                {
                    finished = true;
                    progress.Close();
                }
            };
            progress.ShowDialog();
        }
    }

    private static string Quote(string value)
    {
        // Callers pass file paths and fixed options. Escape trailing slashes for Windows argument parsing.
        return "\"" + value.Replace("\"", "\\\"") + new string('\\', value.Length - value.TrimEnd('\\').Length) + "\"";
    }

    private static string RunNode(string script, params string[] args)
    {
        var start = new ProcessStartInfo(Path.Combine(Root, "windows", "runtime", "node.exe"))
        {
            Arguments = String.Join(" ", new[] { Path.Combine(Root, "windows", "patch", script) }.Concat(args).Select(Quote)),
            WorkingDirectory = Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        start.EnvironmentVariables.Remove("NODE_OPTIONS");
        start.EnvironmentVariables.Remove("NODE_PATH");
        start.EnvironmentVariables.Remove("NODE_TLS_REJECT_UNAUTHORIZED");
        using (Process process = Process.Start(start))
        {
            var stdout = process.StandardOutput.ReadToEndAsync();
            var stderr = process.StandardError.ReadToEndAsync();
            process.WaitForExit();
            if (process.ExitCode != 0)
            {
                string error = stderr.Result.Trim();
                throw new InvalidOperationException(error.Length > 0 ? error : "Helper exit code: " + process.ExitCode);
            }
            return stdout.Result;
        }
    }

    internal sealed class Preferences
    {
        public bool autoCheckUpdates { get; set; }
        public bool showShort { get; set; }
        public bool showWeekly { get; set; }
        public bool showResetTimes { get; set; }
        public bool showResetCredits { get; set; }
        public bool expandCards { get; set; }

        public Preferences()
        {
            autoCheckUpdates = showShort = showWeekly = showResetTimes = showResetCredits = expandCards = true;
        }
    }

    internal static Preferences ReadPreferences()
    {
        if (!File.Exists(PreferencesFile)) return new Preferences();
        try { return new JavaScriptSerializer().Deserialize<Preferences>(File.ReadAllText(PreferencesFile)) ?? new Preferences(); }
        catch (ArgumentException) { return new Preferences(); }
        catch (InvalidOperationException) { return new Preferences(); }
    }

    internal static void SavePreferences(Preferences preferences)
    {
        string temporary = PreferencesFile + "." + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, new JavaScriptSerializer().Serialize(preferences));
            if (File.Exists(PreferencesFile)) File.Replace(temporary, PreferencesFile, null);
            else File.Move(temporary, PreferencesFile);
        }
        finally { File.Delete(temporary); }
    }

    internal sealed class Update
    {
        public string version { get; set; }
        public string sha256 { get; set; }
        public int size { get; set; }
    }

    internal sealed class Compatibility
    {
        public string packageVersion { get; set; }
        public string clientVersion { get; set; }
        public string status { get; set; }
        public bool resetCredits { get; set; }
        public bool pin { get; set; }
        public string reason { get; set; }
    }

    internal static Compatibility CheckCompatibility()
    {
        string version = null;
        try
        {
            string app = FindStoreClient(out version);
            if (app == null)
                return new Compatibility { packageVersion = version, status = version == null ? "missing" : "unavailable" };
            var report = new JavaScriptSerializer().Deserialize<Compatibility>(RunNode("manage.mjs", "compatibility", app));
            report.packageVersion = version;
            return report;
        }
        catch (Exception error)
        {
            return new Compatibility { packageVersion = version, status = "unavailable", reason = error.Message };
        }
    }

    internal static string InstalledVersion()
    {
        return File.ReadAllText(VersionFile).Trim();
    }

    internal static Update FindUpdate(string installed)
    {
        return new JavaScriptSerializer().Deserialize<Update>(RunNode("update-release.mjs", "check", installed));
    }

    internal static T WithUpdateLock<T>(Func<T> action)
    {
        using (var mutex = new Mutex(false, UpdateMutex))
        {
            bool acquired;
            try { acquired = mutex.WaitOne(0); }
            catch (AbandonedMutexException) { acquired = true; }
            if (!acquired) throw new InvalidOperationException("另一个窗口正在检查或下载更新。");
            try { return action(); }
            finally { mutex.ReleaseMutex(); }
        }
    }

    private static void DeleteUpdateDownload(string directory)
    {
        try
        {
            File.Delete(Path.Combine(directory, SetupName));
            File.Delete(Path.Combine(directory, SetupName + ".part"));
            if (Directory.Exists(directory)) Directory.Delete(directory);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    internal static void StartUpdate(Update update, string installed)
    {
        if (InstalledVersion() != installed) throw new InvalidOperationException("本机版本已改变，请重新检查。");
        string download = Path.Combine(Local, "update-download");
        DeleteUpdateDownload(download);
        if (Directory.Exists(download)) throw new IOException("已有安装向导正在使用更新包。");
        Directory.CreateDirectory(download);
        string setup = Path.Combine(download, SetupName);
        try
        {
            RunNode("update-release.mjs", "download", update.version, update.sha256, update.size.ToString(CultureInfo.InvariantCulture), setup);
            if (InstalledVersion() != installed) throw new InvalidOperationException("本机版本已改变，请重新检查。");
            using (Process installer = Process.Start(new ProcessStartInfo(setup) { UseShellExecute = true })) { }
            UsageBarTray.SignalExit(Root);
        }
        catch
        {
            DeleteUpdateDownload(download);
            throw;
        }
    }

    private static bool CheckForUpdate()
    {
        bool accepted = false;
        try
        {
            return WithUpdateLock(() =>
            {
                if (!File.Exists(VersionFile)) return false;
                string installed = InstalledVersion();
                var update = FindUpdate(installed);
                if (update == null) return false;
                string text = "Windows 版有更新：v" + installed + " → v" + update.version + "。" +
                    "\n\n是否下载安装包并打开向导？安装前请保存工作并退出当前 Codex UsageBar。";
                accepted = MessageBox.Show(text, Title, MessageBoxButtons.YesNo, MessageBoxIcon.Information,
                    MessageBoxDefaultButton.Button2) == DialogResult.Yes;
                if (accepted) StartUpdate(update, installed);
                return accepted;
            });
        }
        catch (Exception)
        {
            if (accepted) MessageBox.Show("更新包下载、校验或启动失败。可从 GitHub 下载 Windows 安装包。",
                Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return false;
        }
    }
}
