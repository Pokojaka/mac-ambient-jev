using System.Text;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MacAmbientJev.WinUI;

public sealed partial class MainWindow : Window
{
    private AppWindow? _appWindow; private EngineProcessClient? _client; private ShellStore? _store;
    private ShellUiContext? _context; private LiveViewModel? _live; private TranscriptScrollAdapter? _scroll;
    private SessionsViewModel? _sessions; private SavedSessionsWindow? _savedSessionsWindow;
    private SettingsViewModel? _settings; private DiagnosticsViewModel? _diagnostics; private SettingsDialog? _settingsDialog;
    private bool _closeStarted, _allowFinalClose;
    private bool _toastRegistered, _deviceLostDialogInFlight, _focusDeviceSelector;
    private DeviceLostNotice? _toastedDeviceLostNotice; private ContentDialog? _deviceLostDialog;
    internal IExecutionProviderCatalog ExecutionProviderCatalog { get; } = new WindowsMLExecutionProviderCatalog();

    public MainWindow()
    {
        Application.Current.Resources.Add("VisibilityConverter", new VisibilityConverter());
        InitializeComponent();
        try { AppNotificationManager.Default.Register(); _toastRegistered = true; }
        catch (Exception exception) { ShowFailure(exception); }
        AppIcon.Apply(AppWindow);
        Root.Loaded += OnRootLoaded;
        try
        {
            ImportButton.CommandParameter = new WindowsPathPicker(this);
            var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
            _appWindow = AppWindow.GetFromWindowId(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(handle));
            _appWindow.Closing += OnAppWindowClosing;
            _client = EngineProcessClient.Start();
            _store = new ShellStore(_client);
            _context = new ShellUiContext(_store, new DispatcherQueueUiDispatcher(
                DispatcherQueue.GetForCurrentThread() ?? throw new InvalidOperationException("The UI dispatcher is unavailable.")), TimeProvider.System);
            _settings = new SettingsViewModel(_context); _diagnostics = new DiagnosticsViewModel(_context);
            _live = new LiveViewModel(_context); Root.DataContext = _live;
            _sessions = new SessionsViewModel(_context, new ExplorerFolderRevealer());
            _scroll = new TranscriptScrollAdapter(TranscriptList, _live, ReportFailureAsync);
            _context.Refreshed += OnContextRefreshed;
        }
        catch (Exception exception) { ShowFailure(exception); }
    }

    private void ShowDeviceLostToast(DeviceLostNotice notice)
    {
        if (!_toastRegistered) throw new InvalidOperationException("アプリ通知の登録に失敗しているため、録音停止の通知を表示できません。");
        var notification = new AppNotificationBuilder().AddText("録音デバイスが切断されました").AddText(notice.Message).BuildNotification();
        AppNotificationManager.Default.Show(notification);
        if (notification.Id == 0) throw new InvalidOperationException("録音停止の通知を表示できませんでした。");
    }

    private async Task ShowDeviceLostNoticeAsync()
    {
        if (_closeStarted || !Root.IsLoaded || _store is not { } store) return;
        var notice = store.State.DeviceLostNotice;
        if (notice is null) return;
        if (!ReferenceEquals(_toastedDeviceLostNotice, notice))
        {
            try { ShowDeviceLostToast(notice); }
            catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
            _toastedDeviceLostNotice = notice;
        }
        if (_settingsDialog is not null || _deviceLostDialogInFlight) return;
        _deviceLostDialogInFlight = true; RefreshSettingsButton();
        try
        {
            var dialog = new ContentDialog
            {
                XamlRoot = Root.XamlRoot, Title = "録音デバイスが切断されました",
                Content = notice.Message + "\n\nここまでの録音は保存されています。",
                PrimaryButtonText = "デバイスを選んで新しく録音", CloseButtonText = "閉じる", DefaultButton = ContentDialogButton.Close
            };
            _deviceLostDialog = dialog; if (await dialog.ShowAsync() == ContentDialogResult.Primary && !_closeStarted)
            {
                var live = _live ?? throw new InvalidOperationException("録音画面を利用できません。");
                await store.ReloadDevicesAsync(live.SelectedSource ?? throw new InvalidOperationException("録音元が選択されていません。"));
                if (!_closeStarted)
                {
                    _focusDeviceSelector = true; (_context ?? throw new InvalidOperationException("設定コンテキストを利用できません。")).RequestRefresh();
                }
            }
        }
        catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
        finally
        {
            if (!_closeStarted)
            {
                try { await store.DismissDeviceLostNoticeAsync(notice); }
                catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
            }
            _deviceLostDialog = null; _deviceLostDialogInFlight = false; RefreshSettingsButton();
            try { if (!_closeStarted) (_context ?? throw new InvalidOperationException("設定コンテキストを利用できません。")).RequestRefresh(); }
            catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
        }
    }

    private async void OnRootLoaded(object sender, RoutedEventArgs args)
    {
        Root.Loaded -= OnRootLoaded;
        if (_closeStarted) return;
        try
        {
            if (_store is not { } store || _live is not { } live) return;
            await store.Initialization;
            if (_closeStarted) return;
            SavedSessionsButton.IsEnabled = !_closeStarted && _store?.State.Phase == ShellPhase.Running;
            RefreshSettingsButton();
            if (live.RefreshDevices.CanExecute(null)) live.RefreshDevices.Execute(null);
            await ShowDeviceLostNoticeAsync();
        }
        catch (Exception exception) { await ReportFailureAsync(exception); }
    }
    private async void OnContextRefreshed(object? sender, EventArgs args)
    {
        _scroll?.Refresh();
        SavedSessionsButton.IsEnabled = !_closeStarted && _store?.State.Phase == ShellPhase.Running;
        RefreshSettingsButton();
        if (!_closeStarted && _focusDeviceSelector && DeviceSelector.IsEnabled && _context is { } context &&
            !context.State.IsPending(EngineCommandName.DevicesList))
        {
            _focusDeviceSelector = false;
            if (!DeviceSelector.Focus(FocusState.Programmatic)) ShowFailure(new InvalidOperationException("録音デバイスの選択欄にフォーカスできません。"));
        }
        try { await ShowDeviceLostNoticeAsync(); }
        catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
    }

    private async void OnSavedSessionsClick(object sender, RoutedEventArgs args)
    {
        if (_closeStarted) return;
        try
        {
            if (_savedSessionsWindow is { } existingWindow) { existingWindow.Activate(); return; }
            var sessions = _sessions ?? throw new InvalidOperationException("The saved sessions view model is unavailable.");
            var window = new SavedSessionsWindow(this, sessions);
            _savedSessionsWindow = window;
            window.Closed += OnSavedSessionsClosed;
            window.Activate();
            if (sessions.List.CanExecute(ShellPageMove.Reload)) sessions.List.Execute(ShellPageMove.Reload);
        }
        catch (Exception exception) { await ReportFailureAsync(exception); }
    }

    private async void OnSettingsClick(object sender, RoutedEventArgs args)
    {
        if (_closeStarted || _settingsDialog is not null || _deviceLostDialogInFlight) return;
        try
        {
            var context = _context ?? throw new InvalidOperationException("The settings context is unavailable.");
            var settings = _settings ?? throw new InvalidOperationException("The settings view model is unavailable.");
            var diagnostics = _diagnostics ?? throw new InvalidOperationException("The diagnostics view model is unavailable.");
            var dialog = new SettingsDialog(context, settings, diagnostics, new WindowsPathPicker(this)) { XamlRoot = Root.XamlRoot };
            _settingsDialog = dialog; SettingsButton.IsEnabled = false; await dialog.ShowAsync();
        }
        catch (Exception exception) { await ReportFailureAsync(exception); }
        finally
        {
            if (_settingsDialog is { } dialog) { dialog.Dispose(); _settingsDialog = null; }
            RefreshSettingsButton();
            try { await ShowDeviceLostNoticeAsync(); }
            catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
        }
    }

    private void RefreshSettingsButton() => SettingsButton.IsEnabled = !_closeStarted && _settingsDialog is null && !_deviceLostDialogInFlight &&
        _context is { State.Capabilities: not null } && _store is
        { Initialization.IsCompleted: true, State: { Capabilities: not null, Phase: ShellPhase.Running or ShellPhase.EngineFailed } };

    private void OnSavedSessionsClosed(object sender, WindowEventArgs args)
    {
        var window = sender as Window ?? throw new InvalidOperationException("The closed saved sessions window is unavailable.");
        window.Closed -= OnSavedSessionsClosed;
        _savedSessionsWindow = null;
    }

    private async Task ReportFailureAsync(Exception exception)
    {
        ShowFailure(exception, _client?.Failure);
        if (_store is not { } store) return;
        try { await store.ReportPresentationFailureAsync(exception); }
        catch (ObjectDisposedException) when (store.State.Phase == ShellPhase.Disposed) { }
    }

    private void ShowFailure(Exception exception, EngineClientFailure? snapshot = null)
    {
        var text = new StringBuilder().Append(exception.GetType().Name).Append(": ").Append(exception.Message);
        if (exception is EngineClientFailedException failed) snapshot = failed.Failure;
        if (snapshot is not null)
        {
            if (exception is not EngineClientFailedException) text.AppendLine().Append(snapshot.Message);
            if (snapshot.LastEngineError is { } engineError) text.AppendLine().Append(engineError.Message);
            text.AppendLine().Append("終了コード: ").Append(snapshot.ExitCode?.ToString() ?? "未確定");
            var stderr = Encoding.UTF8.GetString(snapshot.Stderr.Bytes);
            if (stderr.Length != 0) text.AppendLine().Append("標準エラー出力: ").Append(stderr);
            if (snapshot.Stderr.DiscardedBytes != 0) text.AppendLine().Append("標準エラー出力の破棄バイト数: ").Append(snapshot.Stderr.DiscardedBytes);
        }
        WindowFailure.Text = text.ToString(); WindowFailure.Visibility = Visibility.Visible;
    }

    private async void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowFinalClose) return;
        args.Cancel = true;
        if (_closeStarted) return;
        _closeStarted = true; Root.IsHitTestVisible = false;
        Toolbar.IsEnabled = false; SavedSessionsButton.IsEnabled = false; ReturnToLatestButton.IsEnabled = false;
        ClosingStatus.Visibility = Visibility.Visible;
        await ShutDownAsync();
    }

    private async Task ShutDownAsync()
    {
        if (_deviceLostDialog is { } deviceLostDialog) { try { deviceLostDialog.Hide(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); } }
        if (_toastRegistered) try { AppNotificationManager.Default.Unregister(); _toastRegistered = false; }
        catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
        if (_settingsDialog is { } settingsDialog)
        { try { settingsDialog.Hide(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); } finally { settingsDialog.Dispose(); _settingsDialog = null; } }
        if (_savedSessionsWindow is { } savedSessionsWindow)
        { try { savedSessionsWindow.Close(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); } }
        if (_scroll is not null)
        { try { _scroll.Dispose(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); } _scroll = null; }
        if (_context is { } context)
        {
            context.Refreshed -= OnContextRefreshed;
            try { context.Dispose(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
            _context = null;
        }
        if (_store is { } store)
        { try { await store.DisposeAsync(); } catch (Exception exception) { ShowFailure(exception, _client?.Failure); } }
        if (_client is not { } client) { FinalClose(); return; }
        Task closeTask;
        try { closeTask = client.CloseAsync(); }
        catch (Exception exception)
        {
            ShowFailure(exception, client.Failure);
            await ResolveCloseFailureAsync(client, Task.FromException(exception)); return;
        }
        await ResolveCloseFailureAsync(client, closeTask);
    }

    private async Task ResolveCloseFailureAsync(EngineProcessClient client, Task closeTask)
    {
        while (true)
        {
            try { await closeTask.WaitAsync(TimeSpan.FromSeconds(60)); FinalClose(); return; }
            catch (Exception exception)
            {
                ShowFailure(exception, client.Failure);
                var dialog = new ContentDialog
                {
                    Title = "終了処理中",
                    Content = "終了処理に時間がかかっています。処理中の録音データが失われる可能性があります。",
                    PrimaryButtonText = "待ち続ける", SecondaryButtonText = "強制終了",
                    DefaultButton = ContentDialogButton.Primary, XamlRoot = Root.XamlRoot
                };
                Root.IsHitTestVisible = true;
                var choice = await dialog.ShowAsync();
                Root.IsHitTestVisible = false;
                if (choice == ContentDialogResult.Secondary)
                {
                    try { client.ForceKill(); }
                    catch (Exception killFailure) { ShowFailure(killFailure, client.Failure); continue; }
                    await client.Completion;
                    try { await closeTask; }
                    catch (Exception closeFailure) { ShowFailure(closeFailure, client.Failure); }
                    FinalClose(); return;
                }
                if (closeTask.IsCompleted)
                {
                    try { await client.Completion.WaitAsync(TimeSpan.FromSeconds(60)); FinalClose(); return; }
                    catch (TimeoutException waitFailure) { ShowFailure(waitFailure, client.Failure); }
                }
            }
        }
    }

    private void FinalClose()
    {
        _allowFinalClose = true;
        if (_appWindow is not null) _appWindow.Closing -= OnAppWindowClosing;
        Close();
    }
}
