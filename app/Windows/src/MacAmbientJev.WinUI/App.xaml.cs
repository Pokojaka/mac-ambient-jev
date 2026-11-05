using System.Runtime.InteropServices;
using MacAmbientJev.Presentation;

namespace MacAmbientJev.WinUI;

public partial class App : Microsoft.UI.Xaml.Application
{
    private readonly ShellLog _log;
    private Microsoft.UI.Xaml.Window? _window;

    public App()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (localAppData.Length == 0) throw new InvalidOperationException("LocalAppData を取得できません。");
        _log = ShellLog.Open(Path.Combine(localAppData, "mac-ambient-jev", "logs"), TimeProvider.System, Environment.ProcessId);
        UnhandledException += (_, args) => _log.Error("Application.UnhandledException: " + args.Message + "\n" + args.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, args) => _log.Error("AppDomain.UnhandledException: " + args.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, args) => _log.Error("TaskScheduler.UnobservedTaskException: " + args.Exception);
        _log.Info(
            "startup\n" +
            $"version: {typeof(App).Assembly.GetName().Version}\n" +
            $"os: {RuntimeInformation.OSDescription}\n" +
            $"architecture: {RuntimeInformation.ProcessArchitecture}\n" +
            $"runtime: {RuntimeInformation.FrameworkDescription}\n" +
            $"base directory: {AppContext.BaseDirectory}");
        InitializeComponent();
    }

    protected override void OnLaunched(Microsoft.UI.Xaml.LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow(_log);
            _window.Activate();
        }
        catch (Exception exception)
        {
            _log.Error("App.OnLaunched failed: " + exception);
            throw;
        }
    }
}
