using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: System.Reflection.AssemblyTitle("DeepSeek Harness")]
[assembly: System.Reflection.AssemblyDescription("Desktop application for DeepSeek Harness")]
[assembly: System.Reflection.AssemblyCompany("DeepSeek Harness Desktop")]
[assembly: System.Reflection.AssemblyProduct("DeepSeek Harness Desktop")]
[assembly: System.Reflection.AssemblyVersion("1.0.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.0.0")]

namespace DeepSeekHarnessDesktop
{
    internal static class Program
    {
        [STAThread]
        private static void Main()
        {
            Bootstrap.Initialize();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    internal static class Bootstrap
    {
        private const string ResourcePrefix = "DeepSeekHarnessDesktop.Resources.";
        private static string runtimeDirectory;

        internal static string LauncherScriptPath
        {
            get { return Path.Combine(runtimeDirectory, "start-dsh-web.cmd"); }
        }

        internal static void Initialize()
        {
            AppDomain.CurrentDomain.AssemblyResolve += ResolveEmbeddedAssembly;

            runtimeDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "DeepSeekHarnessDesktop", "Runtime", "1.0.0");
            Directory.CreateDirectory(runtimeDirectory);

            string loaderPath = ExtractResource("WebView2Loader.dll", "WebView2Loader.dll");
            ExtractResource("start-dsh-web.cmd", "start-dsh-web.cmd");
            LoadLibrary(loaderPath);
        }

        private static Assembly ResolveEmbeddedAssembly(object sender, ResolveEventArgs args)
        {
            string simpleName = new AssemblyName(args.Name).Name;
            if (simpleName != "Microsoft.Web.WebView2.Core" &&
                simpleName != "Microsoft.Web.WebView2.WinForms") return null;

            byte[] bytes = ReadResource(simpleName + ".dll");
            return Assembly.Load(bytes);
        }

        private static string ExtractResource(string resourceName, string fileName)
        {
            string path = Path.Combine(runtimeDirectory, fileName);
            byte[] bytes = ReadResource(resourceName);
            if (!File.Exists(path) || new FileInfo(path).Length != bytes.Length)
                File.WriteAllBytes(path, bytes);
            return path;
        }

        private static byte[] ReadResource(string name)
        {
            Assembly assembly = Assembly.GetExecutingAssembly();
            using (Stream stream = assembly.GetManifestResourceStream(ResourcePrefix + name))
            {
                if (stream == null) throw new InvalidOperationException("缺少内置资源：" + name);
                byte[] bytes = new byte[stream.Length];
                int offset = 0;
                while (offset < bytes.Length)
                {
                    int count = stream.Read(bytes, offset, bytes.Length - offset);
                    if (count == 0) break;
                    offset += count;
                }
                return bytes;
            }
        }

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr LoadLibrary(string path);
    }

    internal sealed class MainForm : Form
    {
        private const string ServerUrl = "http://127.0.0.1:3080";
        private const string DshDlxCommand =
            "pnpm dlx --reporter append-only " +
            "--allow-build=@deepseek-ai/dsh-subprocess-local " +
            "--allow-build=@google/genai " +
            "--allow-build=koffi " +
            "--allow-build=node-pty " +
            "--allow-build=protobufjs " +
            "@deepseek-ai/dsh";
        private readonly WebView2 webView;
        private readonly Panel loadingPanel;
        private readonly Panel loadingCard;
        private readonly Label loadingTitle;
        private readonly Label statusLabel;
        private readonly ProgressBar progressBar;
        private readonly TextBox detailsBox;
        private readonly Button retryButton;
        private readonly StringBuilder serverLog = new StringBuilder();
        private readonly object logLock = new object();

        private Process serverProcess;
        private Icon themeIcon;
        private CancellationTokenSource startupCancellation;
        private bool ownsServer;
        private bool booting;
        private bool closing;
        private TaskCompletionSource<bool> navigationReady;
        private bool navigationHandlersAttached;

        private string DataDirectory
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "DeepSeekHarnessDesktop");
            }
        }

        public MainForm()
        {
            Text = "DeepSeek Harness";
            StartPosition = FormStartPosition.CenterScreen;
            Size = new Size(1280, 820);
            MinimumSize = new Size(900, 600);
            BackColor = Color.FromArgb(246, 247, 249);
            Font = new Font("Microsoft YaHei UI", 9F, FontStyle.Regular, GraphicsUnit.Point);
            AutoScaleMode = AutoScaleMode.Dpi;
            KeyPreview = true;
            HandleCreated += delegate { ApplyWindowTheme(); };
            SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

            Panel mainPanel = new Panel();
            mainPanel.Dock = DockStyle.Fill;

            webView = new WebView2();
            webView.Dock = DockStyle.Fill;
            webView.Visible = false;

            loadingPanel = new Panel();
            loadingPanel.Dock = DockStyle.Fill;
            loadingPanel.BackColor = Color.FromArgb(246, 247, 249);

            loadingCard = new Panel();
            loadingCard.Size = new Size(680, 430);
            loadingCard.BackColor = Color.White;
            loadingCard.Padding = new Padding(36);

            loadingTitle = new Label();
            loadingTitle.Text = "正在启动 DeepSeek Harness";
            loadingTitle.Font = new Font("Microsoft YaHei UI", 17F, FontStyle.Bold);
            loadingTitle.AutoSize = true;
            loadingTitle.Location = new Point(36, 34);

            statusLabel = new Label();
            statusLabel.Text = "正在准备本地服务…";
            statusLabel.ForeColor = Color.FromArgb(74, 84, 99);
            statusLabel.AutoEllipsis = true;
            statusLabel.Location = new Point(38, 84);
            statusLabel.Size = new Size(600, 28);

            progressBar = new ProgressBar();
            progressBar.Style = ProgressBarStyle.Marquee;
            progressBar.MarqueeAnimationSpeed = 22;
            progressBar.Location = new Point(38, 126);
            progressBar.Size = new Size(600, 6);

            detailsBox = new TextBox();
            detailsBox.Multiline = true;
            detailsBox.ReadOnly = true;
            detailsBox.ScrollBars = ScrollBars.Vertical;
            detailsBox.BackColor = Color.FromArgb(248, 249, 251);
            detailsBox.BorderStyle = BorderStyle.FixedSingle;
            detailsBox.Font = new Font("Consolas", 8.5F);
            detailsBox.Location = new Point(38, 156);
            detailsBox.Size = new Size(600, 190);
            detailsBox.Visible = true;

            retryButton = new Button();
            retryButton.Text = "重试";
            retryButton.Size = new Size(92, 34);
            retryButton.Location = new Point(38, 366);
            retryButton.FlatStyle = FlatStyle.Flat;
            retryButton.BackColor = Color.FromArgb(38, 99, 235);
            retryButton.ForeColor = Color.White;
            retryButton.FlatAppearance.BorderSize = 0;
            retryButton.Visible = false;

            loadingCard.Controls.Add(loadingTitle);
            loadingCard.Controls.Add(statusLabel);
            loadingCard.Controls.Add(progressBar);
            loadingCard.Controls.Add(detailsBox);
            loadingCard.Controls.Add(retryButton);
            loadingPanel.Controls.Add(loadingCard);
            loadingPanel.Resize += delegate { CenterLoadingCard(); };

            mainPanel.Controls.Add(webView);
            mainPanel.Controls.Add(loadingPanel);
            Controls.Add(mainPanel);

            retryButton.Click += async delegate { await BootAsync(true); };
            KeyDown += delegate(object sender, KeyEventArgs e)
            {
                if ((e.Control && e.KeyCode == Keys.R) || e.KeyCode == Keys.F5)
                {
                    if (webView.CoreWebView2 != null) webView.CoreWebView2.Reload();
                    e.Handled = true;
                    e.SuppressKeyPress = true;
                }
            };
            Shown += async delegate { await BootAsync(false); };
            FormClosing += OnFormClosing;

            CenterLoadingCard();
            ApplyLoadingTheme();
        }

        private void CenterLoadingCard()
        {
            loadingCard.Left = Math.Max(12, (loadingPanel.ClientSize.Width - loadingCard.Width) / 2);
            loadingCard.Top = Math.Max(12, (loadingPanel.ClientSize.Height - loadingCard.Height) / 2 - 20);
        }

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (closing || !IsHandleCreated) return;
            BeginInvoke(new Action(delegate
            {
                ApplyWindowTheme();
                ApplyLoadingTheme();
                ApplyWebViewTheme();
            }));
        }

        private void ApplyWindowTheme()
        {
            bool dark = IsSystemDarkMode();
            int enabled = dark ? 1 : 0;
            DwmSetWindowAttribute(Handle, 20, ref enabled, sizeof(int));
            DwmSetWindowAttribute(Handle, 19, ref enabled, sizeof(int));

            string resource = dark
                ? "DeepSeekHarnessDesktop.Resources.whale-white.ico"
                : "DeepSeekHarnessDesktop.Resources.whale-blue.ico";
            using (Stream stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(resource))
            {
                if (stream == null) return;
                Icon replacement = (Icon)new Icon(stream).Clone();
                Icon previous = themeIcon;
                themeIcon = replacement;
                Icon = themeIcon;
                if (previous != null) previous.Dispose();
            }
        }

        private void ApplyLoadingTheme()
        {
            bool dark = IsSystemDarkMode();

            BackColor = dark ? Color.FromArgb(23, 24, 26) : Color.FromArgb(246, 247, 249);
            loadingPanel.BackColor = BackColor;
            loadingCard.BackColor = dark ? Color.FromArgb(43, 45, 49) : Color.White;
            loadingTitle.ForeColor = dark ? Color.FromArgb(232, 234, 237) : Color.Black;
            statusLabel.ForeColor = dark ? Color.FromArgb(176, 181, 188) : Color.FromArgb(74, 84, 99);
            detailsBox.BackColor = dark ? Color.FromArgb(32, 33, 36) : Color.FromArgb(248, 249, 251);
            detailsBox.ForeColor = dark ? Color.FromArgb(208, 211, 215) : Color.Black;
        }

        private void ApplyWebViewTheme()
        {
            if (webView == null || webView.CoreWebView2 == null) return;

            bool dark = IsSystemDarkMode();
            webView.DefaultBackgroundColor =
                dark ? Color.FromArgb(23, 24, 26) : Color.FromArgb(246, 247, 249);
        }

        private static bool IsSystemDarkMode()
        {
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(
                    @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
                {
                    object value = key == null ? null : key.GetValue("AppsUseLightTheme");
                    return value is int && (int)value == 0;
                }
            }
            catch
            {
                return false;
            }
        }

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(
            IntPtr hwnd, int attribute, ref int value, int valueSize);

        private async Task<string> FetchHarnessVersionAsync()
        {
            try
            {
                return await Task.Run<string>(delegate
                {
                    ProcessStartInfo info = new ProcessStartInfo();
                    info.FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
                    info.Arguments = "/d /s /c \"" + DshDlxCommand + " -V\"";
                    info.WorkingDirectory = GetLaunchDirectory();
                    info.UseShellExecute = false;
                    info.CreateNoWindow = true;
                    info.WindowStyle = ProcessWindowStyle.Hidden;
                    info.RedirectStandardOutput = true;
                    info.RedirectStandardError = true;

                    using (Process process = Process.Start(info))
                    {
                        if (process == null) return string.Empty;
                        string stdout = process.StandardOutput.ReadToEnd();
                        string stderr = process.StandardError.ReadToEnd();
                        process.WaitForExit();

                        string[] lines = (stdout + "\r\n" + stderr)
                            .Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
                        for (int i = lines.Length - 1; i >= 0; i--)
                        {
                            string line = lines[i].Trim();
                            if (Regex.IsMatch(line, @"^\d+\.\d+\.\d+([-.][0-9A-Za-z.-]+)*$"))
                                return line;
                        }
                        return string.Empty;
                    }
                });
            }
            catch
            {
                return string.Empty;
            }
        }

        private void ApplyHarnessVersion(string version)
        {
            if (string.IsNullOrWhiteSpace(version) || IsDisposed) return;
            Text = "DeepSeek Harness " + version;
        }

        private async void UpdateHarnessVersionAsync()
        {
            string version = await FetchHarnessVersionAsync();
            ApplyHarnessVersion(version);
        }

        private async Task BootAsync(bool restart)
        {
            if (booting || closing) return;
            booting = true;
            retryButton.Visible = false;
            detailsBox.Visible = true;
            detailsBox.Text = "正在检查启动环境…" + Environment.NewLine;
            progressBar.Visible = true;
            progressBar.Style = ProgressBarStyle.Marquee;
            webView.Visible = false;
            loadingPanel.Visible = true;
            loadingPanel.BringToFront();

            startupCancellation = new CancellationTokenSource();
            CancellationToken token = startupCancellation.Token;

            try
            {
                if (restart && ownsServer)
                {
                    statusLabel.Text = "正在重启本地服务…";
                    StopOwnedServer();
                    await Task.Delay(800);
                }

                statusLabel.Text = "正在初始化桌面窗口…";
                await EnsureWebViewAsync();

                if (!await ProbeServerAsync())
                {
                    statusLabel.Text = "首次启动可能需要 30–90 秒，正在准备依赖…";
                    StartServer();
                }
                else
                {
                    ownsServer = false;
                    statusLabel.Text = "已连接到正在运行的本地服务…";
                }

                bool ready = await WaitForServerAsync(token);
                if (!ready)
                {
                    throw new InvalidOperationException(
                        "本地服务未能在规定时间内启动。\r\n\r\n" + GetLogTail());
                }

                statusLabel.Text = "正在载入界面…";
                TaskCompletionSource<bool> navTcs = new TaskCompletionSource<bool>();
                navigationReady = navTcs;
                webView.CoreWebView2.Navigate(ServerUrl);

                Task navTask = navTcs.Task;
                Task done = await Task.WhenAny(navTask, Task.Delay(15000, token));
                if (done != navTask)
                {
                    throw new InvalidOperationException("界面载入超时。");
                }

                webView.Visible = true;
                webView.BringToFront();
                loadingPanel.Visible = false;
                UpdateHarnessVersionAsync();
            }
            catch (OperationCanceledException)
            {
            }
            catch (Exception ex)
            {
                ShowFailure(ex.Message);
            }
            finally
            {
                booting = false;
            }
        }

        private async Task EnsureWebViewAsync()
        {
            if (webView.CoreWebView2 != null) return;

            Directory.CreateDirectory(DataDirectory);
            string userData = Path.Combine(DataDirectory, "WebView2");
            CoreWebView2Environment environment =
                await CoreWebView2Environment.CreateAsync(null, userData);
            await webView.EnsureCoreWebView2Async(environment);

            webView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            webView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = true;
            webView.CoreWebView2.Settings.AreDevToolsEnabled = true;
            webView.CoreWebView2.NewWindowRequested += delegate(object sender, CoreWebView2NewWindowRequestedEventArgs e)
            {
                e.Handled = true;
                OpenExternal(e.Uri);
            };

            if (!navigationHandlersAttached)
            {
                navigationHandlersAttached = true;
                webView.CoreWebView2.NavigationCompleted += OnNavigationCompleted;
            }

            ApplyWebViewTheme();
        }

        private void OnNavigationCompleted(object sender, CoreWebView2NavigationCompletedEventArgs e)
        {
            TaskCompletionSource<bool> tcs = navigationReady;
            navigationReady = null;
            if (tcs != null) tcs.TrySetResult(e.IsSuccess);
        }

        private void StartServer()
        {
            string script = Bootstrap.LauncherScriptPath;
            if (!File.Exists(script))
            {
                throw new FileNotFoundException("找不到 DSH 启动脚本。", script);
            }

            lock (logLock) serverLog.Length = 0;

            ProcessStartInfo info = new ProcessStartInfo();
            info.FileName = Environment.GetEnvironmentVariable("COMSPEC") ?? "cmd.exe";
            info.Arguments = "/d /s /c \"\"" + script + "\"\"";
            info.WorkingDirectory = GetLaunchDirectory();
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.WindowStyle = ProcessWindowStyle.Hidden;
            info.RedirectStandardOutput = true;
            info.RedirectStandardError = true;

            serverProcess = new Process();
            serverProcess.StartInfo = info;
            serverProcess.EnableRaisingEvents = true;
            serverProcess.OutputDataReceived += OnServerOutput;
            serverProcess.ErrorDataReceived += OnServerOutput;
            serverProcess.Start();
            serverProcess.BeginOutputReadLine();
            serverProcess.BeginErrorReadLine();
            ownsServer = true;
        }

        private void OnServerOutput(object sender, DataReceivedEventArgs e)
        {
            if (string.IsNullOrEmpty(e.Data)) return;
            lock (logLock)
            {
                serverLog.AppendLine(e.Data);
                if (serverLog.Length > 24000)
                    serverLog.Remove(0, serverLog.Length - 18000);
            }

            try
            {
                if (IsHandleCreated && !IsDisposed)
                    BeginInvoke(new Action<string>(AppendVisibleLog), e.Data);
            }
            catch
            {
            }
        }

        private void AppendVisibleLog(string text)
        {
            if (closing || IsDisposed || !booting) return;

            string line = text + Environment.NewLine;
            if (detailsBox.TextLength + line.Length > 18000)
            {
                int keepFrom = Math.Max(0, detailsBox.TextLength - 14000);
                detailsBox.Text = detailsBox.Text.Substring(keepFrom);
            }
            detailsBox.AppendText(line);
            detailsBox.SelectionStart = detailsBox.TextLength;
            detailsBox.ScrollToCaret();
        }

        private async Task<bool> WaitForServerAsync(CancellationToken token)
        {
            for (int i = 0; i < 180; i++)
            {
                token.ThrowIfCancellationRequested();

                if (await ProbeServerAsync()) return true;

                if (serverProcess != null && serverProcess.HasExited)
                {
                    throw new InvalidOperationException(
                        "本地服务提前退出。\r\n\r\n" + GetLogTail());
                }

                int elapsed = i + 1;
                if (elapsed > 5)
                    statusLabel.Text = string.Format("正在启动本地服务… 已等待 {0} 秒", elapsed);

                await Task.Delay(1000, token);
            }
            return false;
        }

        private static Task<bool> ProbeServerAsync()
        {
            return Task.Run<bool>(delegate
            {
                try
                {
                    HttpWebRequest request = (HttpWebRequest)WebRequest.Create(ServerUrl);
                    request.Method = "GET";
                    request.Timeout = 1400;
                    request.ReadWriteTimeout = 1400;
                    request.Proxy = null;
                    using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                    {
                        int code = (int)response.StatusCode;
                        return code >= 200 && code < 500;
                    }
                }
                catch
                {
                    return false;
                }
            });
        }

        private string GetLaunchDirectory()
        {
            string current = Environment.CurrentDirectory;
            if (Directory.Exists(current)) return current;
            return AppDomain.CurrentDomain.BaseDirectory;
        }

        private string GetLogTail()
        {
            lock (logLock)
            {
                string text = serverLog.ToString().Trim();
                if (text.Length > 7000) text = text.Substring(text.Length - 7000);
                return text;
            }
        }

        private void ShowFailure(string message)
        {
            statusLabel.Text = "启动失败";
            progressBar.Visible = false;
            detailsBox.Text = message;
            detailsBox.Visible = true;
            retryButton.Visible = true;
            loadingPanel.Visible = true;
            loadingPanel.BringToFront();
        }

        private static void OpenExternal(string url)
        {
            try
            {
                ProcessStartInfo info = new ProcessStartInfo(url);
                info.UseShellExecute = true;
                Process.Start(info);
            }
            catch
            {
            }
        }

        private void StopOwnedServer()
        {
            if (!ownsServer || serverProcess == null) return;

            try
            {
                if (!serverProcess.HasExited)
                {
                    ProcessStartInfo killInfo = new ProcessStartInfo();
                    killInfo.FileName = "taskkill.exe";
                    killInfo.Arguments = "/PID " + serverProcess.Id + " /T /F";
                    killInfo.UseShellExecute = false;
                    killInfo.CreateNoWindow = true;
                    killInfo.WindowStyle = ProcessWindowStyle.Hidden;
                    using (Process killer = Process.Start(killInfo))
                    {
                        if (killer != null) killer.WaitForExit(4000);
                    }
                }
            }
            catch
            {
            }
            finally
            {
                try { serverProcess.Dispose(); } catch { }
                serverProcess = null;
                ownsServer = false;
            }
        }

        private void OnFormClosing(object sender, FormClosingEventArgs e)
        {
            closing = true;
            SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
            if (startupCancellation != null) startupCancellation.Cancel();
            StopOwnedServer();
            if (themeIcon != null) themeIcon.Dispose();
        }
    }
}
