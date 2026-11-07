using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
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
                WithLock(Launch);
                CheckForUpdate();
            }
            else if (args[0] == "install" && args.Length == 2)
            {
                WithLock(() => RunNode("packaged-client.mjs", "install", FindStoreClient()));
                File.WriteAllText(args[1], "Store client copy prepared and verified." + Environment.NewLine);
            }
            else if (args[0] == "verify") RunNode("packaged-client.mjs", "verify");
            else if (args[0] == "check-client" && args.Length == 2)
                AssertClosed(Path.Combine(args[1], ".local", "windows-sidebar-client"));
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
            if (args.Length == 0) MessageBox.Show(error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            if (args.Length == 2 && args[0] == "install")
            {
                try { File.WriteAllText(args[1], error.Message + Environment.NewLine); } catch (IOException) { }
            }
            return 1;
        }
    }

    private static string FindStoreClient()
    {
        const int InsufficientBuffer = 122;
        int count = 0, length = 0;
        if (GetPackagesByPackageFamily(StoreFamily, ref count, null, ref length, IntPtr.Zero) != InsufficientBuffer)
            throw new InvalidOperationException("Install the official Codex client from Microsoft Store first.");
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
                int pathLength = 0;
                if (GetPackagePathByFullName(package.Name, ref pathLength, null) != InsufficientBuffer) continue;
                var path = new StringBuilder(pathLength);
                if (GetPackagePathByFullName(package.Name, ref pathLength, path) != 0) continue;
                string app = Path.Combine(path.ToString(), "app");
                if (File.Exists(Path.Combine(app, "ChatGPT.exe")) && File.Exists(Path.Combine(app, "resources", "app.asar")))
                    return app;
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
        throw new InvalidOperationException("A supported Microsoft Store Codex installation was not found.");
    }

    private static void WithLock(Action action)
    {
        Directory.CreateDirectory(Local);
        string path = Path.Combine(Local, "windows-sidebar-launch.lock");
        FileStream lease = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None);
        try { action(); }
        finally
        {
            lease.Dispose();
            File.Delete(path);
        }
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

    private static void Launch()
    {
        RunNode("packaged-client.mjs", "verify");
        foreach (Process process in Process.GetProcessesByName("ChatGPT"))
        {
            using (process)
            {
                if (!String.Equals(ProcessPath(process), ClientExe, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException(ExitMessage);
            }
        }
        Process.Start(new ProcessStartInfo(ClientExe) { WorkingDirectory = Client, UseShellExecute = true });
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

    private sealed class Update
    {
        public string version { get; set; }
        public string sha256 { get; set; }
        public int size { get; set; }
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

    private static void CheckForUpdate()
    {
        bool ownsMutex = false, accepted = false;
        string temporary = null;
        using (var mutex = new Mutex(false, @"Local\CodexUsageBarWindowsUpdate"))
        {
            try
            {
                if (!File.Exists(VersionFile)) return;
                try { ownsMutex = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { ownsMutex = true; }
                if (!ownsMutex) return;
                string download = Path.Combine(Local, "update-download");
                DeleteUpdateDownload(download);
                string installed = File.ReadAllText(VersionFile).Trim();
                var update = new JavaScriptSerializer().Deserialize<Update>(RunNode("update-release.mjs", "check", installed));
                if (update == null) return;
                string text = "Windows 版有更新：v" + installed + " → v" + update.version + "。" +
                    "\n\n是否下载安装包并打开向导？安装前请保存工作并退出当前 Codex UsageBar。";
                accepted = MessageBox.Show(text, Title, MessageBoxButtons.YesNo, MessageBoxIcon.Information,
                    MessageBoxDefaultButton.Button2) == DialogResult.Yes;
                if (!accepted) return;
                if (Directory.Exists(download)) throw new IOException("An installer is still in use.");
                temporary = download;
                Directory.CreateDirectory(temporary);
                string setup = Path.Combine(temporary, SetupName);
                RunNode("update-release.mjs", "download", update.version, update.sha256, update.size.ToString(CultureInfo.InvariantCulture), setup);
                if (!File.Exists(VersionFile) || File.ReadAllText(VersionFile).Trim() != installed) return;
                using (Process installer = Process.Start(new ProcessStartInfo(setup) { UseShellExecute = true })) { }
                // Setup replaces this launcher, so exit and clean the download on a later launch.
                temporary = null;
            }
            catch (Exception)
            {
                if (accepted) MessageBox.Show("更新包下载、校验或启动失败。可从 GitHub 下载 Windows 安装包。",
                    Title, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            finally
            {
                if (temporary != null) DeleteUpdateDownload(temporary);
                if (ownsMutex) mutex.ReleaseMutex();
            }
        }
    }
}
