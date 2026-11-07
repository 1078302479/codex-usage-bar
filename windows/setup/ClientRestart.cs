using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using FILETIME = System.Runtime.InteropServices.ComTypes.FILETIME;

internal static class ClientRestart
{
    [StructLayout(LayoutKind.Sequential)]
    private struct UniqueProcess
    {
        public int Id;
        public FILETIME StartTime;
    }

    [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)]
    private static extern int RmStartSession(out uint session, int flags, StringBuilder key);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmRegisterResources(uint session, uint files, IntPtr filenames,
        uint count, [In] UniqueProcess[] processes, uint services, IntPtr serviceNames);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmShutdown(uint session, uint flags, IntPtr callback);

    [DllImport("rstrtmgr.dll")]
    private static extern int RmEndSession(uint session);

    internal static void Request(Process client)
    {
        long start = client.StartTime.ToFileTimeUtc();
        var target = new UniqueProcess
        {
            Id = client.Id,
            StartTime = new FILETIME { dwLowDateTime = unchecked((int)start), dwHighDateTime = (int)(start >> 32) }
        };
        uint session;
        int result = RmStartSession(out session, 0, new StringBuilder(33));
        if (result == 0)
        {
            try
            {
                result = RmRegisterResources(session, 0, IntPtr.Zero, 1, new[] { target }, 0, IntPtr.Zero);
                // No RmForceShutdown flag: allow the app to reject the request.
                if (result == 0) result = RmShutdown(session, 0, IntPtr.Zero);
            }
            finally { RmEndSession(session); }
        }
        if (result != 0) throw new InvalidOperationException("Codex 暂未接受退出请求（Windows 错误 " + result + "）。");
    }
}
