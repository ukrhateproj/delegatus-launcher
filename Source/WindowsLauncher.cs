using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Windows.Forms;
using System.Reflection;
[assembly: AssemblyTitle("Delegatus Launcher")]
[assembly: AssemblyDescription("Community launcher for Delegatus")]
[assembly: AssemblyProduct("Delegatus Launcher")]
[assembly: AssemblyVersion("2.0.1.0")]
[assembly: AssemblyFileVersion("2.0.1.0")]
internal static class Program {
    private static string Quote(string value) {
        StringBuilder b = new StringBuilder("\""); int slashes = 0;
        foreach (char ch in value) {
            if (ch == '\\') { slashes++; continue; }
            if (ch == '"') { b.Append('\\', slashes * 2 + 1); b.Append('"'); }
            else { b.Append('\\', slashes); b.Append(ch); }
            slashes = 0;
        }
        b.Append('\\', slashes * 2); b.Append('"'); return b.ToString();
    }
    [STAThread]
    private static int Main() {
        Application.EnableVisualStyles();
        try {
            string package = AppDomain.CurrentDomain.BaseDirectory;
            string source = Path.Combine(package, "Resources", "Launch-Delegatus.ps1");
            if (!File.Exists(source)) throw new FileNotFoundException("Extract the entire archive first. Resources must remain next to Delegatus.exe.");
            string windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string host = Path.Combine(windows, (!Environment.Is64BitProcess && Environment.Is64BitOperatingSystem) ? "Sysnative" : "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            if (!File.Exists(host)) throw new FileNotFoundException("Windows PowerShell 5.1 was not found. Windows 10 or Windows 11 is required.");
            string logs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Delegatus Launcher", "Logs");
            Directory.CreateDirectory(logs);
            string log = Path.Combine(logs, "bootstrap-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0,8) + ".log");
            string command = "try { $p=[IO.Path]::Combine($env:DELEGATUS_PACKAGE_DIR,'Resources','Launch-Delegatus.ps1'); $s=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($s)) } catch { Add-Type -AssemblyName System.Windows.Forms; [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Delegatus Launcher'); exit 1 }";
            ProcessStartInfo start = new ProcessStartInfo(host);
            start.Arguments = "-NoLogo -NoProfile -STA -Command " + Quote(command);
            start.WorkingDirectory = package;
            start.UseShellExecute = false; start.CreateNoWindow = true;
            start.RedirectStandardOutput = true; start.RedirectStandardError = true;
            start.EnvironmentVariables["DELEGATUS_PACKAGE_DIR"] = package;
            start.EnvironmentVariables["DELEGATUS_GUI"] = "1";
            object gate = new object();
            using (StreamWriter writer = new StreamWriter(log, false, new UTF8Encoding(false)))
            using (Process process = new Process()) {
                writer.AutoFlush = true; process.StartInfo = start;
                DataReceivedEventHandler receive = delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null) { lock(gate) { writer.WriteLine(e.Data); } } };
                process.OutputDataReceived += receive; process.ErrorDataReceived += receive;
                process.Start(); process.BeginOutputReadLine(); process.BeginErrorReadLine();
                process.WaitForExit();
                return process.ExitCode;
            }
        } catch (Exception error) {
            MessageBox.Show(error.Message, "Delegatus Launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
