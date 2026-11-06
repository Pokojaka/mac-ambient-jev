using System.Reflection;
using System.Runtime.InteropServices;
using MacAmbientJev.Presentation;

namespace MacAmbientJev.WinUI;

public partial class App : Microsoft.UI.Xaml.Application
{
    private readonly ShellLog _log;
    private MainWindow? _window;
    private readonly TaskCompletionSource<MainWindow> _windowReady = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public App()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (localAppData.Length == 0) throw new InvalidOperationException("LocalAppData を取得できません。");
        _log = ShellLog.Open(Path.Combine(localAppData, "mac-ambient-jev", "logs"), TimeProvider.System, Environment.ProcessId, File.Delete);
        UnhandledException += (_, args) => _log.Error("Application.UnhandledException: " + args.Message + "\n" + args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => _log.Error("AppDomain.UnhandledException: " + args.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, args) => _log.Error("TaskScheduler.UnobservedTaskException: " + args.Exception);
        _log.Info(
            "startup\n" +
            $"version: {typeof(App).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? throw new InvalidOperationException("The informational version is unavailable.")}\n" +
            $"os: {RuntimeInformation.OSDescription}\n" +
            $"architecture: {RuntimeInformation.ProcessArchitecture}\n" +
            $"runtime: {RuntimeInformation.FrameworkDescription}\n" +
            $"base directory: {AppContext.BaseDirectory}");
        try { InitializeComponent(); }
        catch (Exception exception)
        {
            _log.Error("App.InitializeComponent failed: " + exception);
            throw;
        }
    }

    internal async Task ActivateFromRedirectAsync()
    {
        // A redirected launch can arrive before OnLaunched has created the window.
        var window = await _windowReady.Task.ConfigureAwait(false);
        if (!window.DispatcherQueue.TryEnqueue(() =>
        {
            window.ActivateFromRedirect();
            _log.Info("redirected activation: existing window activated");
        }))
            throw new InvalidOperationException("既存のウィンドウのアクティブ化を予約できません。");
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow(_log);
            _window.Activate();
            _windowReady.SetResult(_window);
        }
        catch (Exception exception)
        {
            _log.Error("App.OnLaunched failed: " + exception);
            throw;
        }
    }
}
