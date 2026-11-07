using System.Runtime.InteropServices;
using System.Text;
using MacAmbientJev.EngineClient;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace MacAmbientJev.WinUI;

public sealed partial class MainWindow : Window
{
    private AppWindow? _appWindow; private EngineProcessClient? _client; private ShellStore? _store;
    private ShellUiContext? _context; private LiveViewModel? _live; private TranscriptScrollAdapter? _scroll;
    private SessionsViewModel? _sessions; private SavedSessionsWindow? _savedSessionsWindow;
    private SettingsViewModel? _settings; private DiagnosticsViewModel? _diagnostics; private SettingsDialog? _settingsDialog;
    private readonly ShellLog _log;
    private bool _closeStarted, _allowFinalClose;
    private bool _toastRegistered, _deviceLostDialogInFlight, _focusDeviceSelector;
    private DeviceLostNotice? _toastedDeviceLostNotice; private ContentDialog? _deviceLostDialog;

    public MainWindow(ShellLog log)
    {
        _log = log ?? throw new ArgumentNullException(nameof(log));
        Application.Current.Resources.Add("VisibilityConverter", new VisibilityConverter());
        Application.Current.Resources.Add("ProcessingAccessibleNameConverter", new ProcessingAccessibleNameConverter());
        Application.Current.Resources.Add("ProcessingAccessibilityViewConverter", new ProcessingAccessibilityViewConverter());
        Application.Current.Resources.Add("IconGlyphConverter", new IconGlyphConverter());
        Application.Current.Resources.Add("IconVisibilityConverter", new IconVisibilityConverter());
        Application.Current.Resources.Add("TopSpacingConverter", new TopSpacingConverter());
        Application.Current.Resources.Add("FirstLineConverter", new FirstLineConverter());
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(UnifiedTitleBar);
        UpdateWindowScale(resize: true);
        Root.SizeChanged += (_, _) => UpdateTitleBarTitle();
        Root.ActualThemeChanged += (_, _) =>
        {
            if (_rowDetailsContent is { } content) content.RequestedTheme = Root.ActualTheme;
        };
        _log.WriteFailed += OnLogWriteFailed;
        if (_log.StartupFailure is { } startupFailure) ShowFailure(startupFailure);
        else if (_log.Failure is { } logFailure) ShowFailure(logFailure);
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
            _client = EngineProcessClient.Start(new EngineLogObserver(_log));
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

    internal bool ActivateFromRedirect()
    {
        if (_closeStarted)
        {
            _log.Info("redirected activation ignored because the app is closing");
            return false;
        }
        if (AppWindow.Presenter is OverlappedPresenter { State: OverlappedPresenterState.Minimized } presenter)
            presenter.Restore();
        AppWindow.Show();
        Activate();
        // Windows may refuse the foreground change; the window is still shown and activated.
        if (!SetForegroundWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)))
            _log.Warn("既存のウィンドウを前面に表示できませんでした。");
        return true;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    private double _windowScale;

    private void UpdateWindowScale(bool resize = false)
    {
        var dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (dpi == 0) throw new InvalidOperationException("ウィンドウの表示倍率を取得できません。");
        var scale = dpi / 96.0;
        if (!resize && scale == _windowScale) return;
        _windowScale = scale;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)Math.Ceiling(720 * scale);
            presenter.PreferredMinimumHeight = (int)Math.Ceiling(480 * scale);
        }
        if (resize) AppWindow.Resize(new Windows.Graphics.SizeInt32((int)Math.Round(900 * scale), (int)Math.Round(620 * scale)));
    }

    private void UpdateTitleBarTitle() => UnifiedTitleBar.Title = Root.ActualWidth >= 960 ? "MacAmbientJev" : string.Empty;

    private void OnLogWriteFailed(Exception exception)
    {
        try
        {
            if (!DispatcherQueue.TryEnqueue(() => ShowFailure(exception))) return;
        }
        catch (Exception) { /* The log has stopped; only the unavailable display is being dropped. */ }
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
        Root.XamlRoot.Changed += (_, _) => UpdateWindowScale();
        UpdateWindowScale();
        UpdateTitleBarTitle();
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
    private void OnTranscriptContainerContentChanging(ListViewBase sender, ContainerContentChangingEventArgs args)
    {
        if (args.InRecycleQueue)
        {
            AutomationProperties.SetName(args.ItemContainer, string.Empty);
            return;
        }

        var row = args.Item as ShellTranscriptRowViewModel ??
            throw new InvalidOperationException("A transcript container has an unexpected item type.");
        AutomationProperties.SetName(args.ItemContainer, row.AccessibleName);
    }

    private async void OnContextRefreshed(object? sender, EventArgs args)
    {
        if (_rowDetailsTail is { } detailsTail)
        {
            var tail = _live?.Transcript.Tail;
            if (_live?.Transcript.SessionID != detailsTail.SessionID ||
                tail is null || !tail.Rows.Any(row => row.RowID == _rowDetailsRowID))
                _rowDetailsFlyout?.Hide();
            else if (tail.Revision != detailsTail.Revision)
            {
                _rowDetailsTail = tail;
                ++_rowDetailsRequest;
                _ = RefreshRowDetailsAsync();
                // A changed live row gets a new container; move the flyout to its new time button.
                if (!DispatcherQueue.TryEnqueue(DispatcherQueuePriority.Low, ReanchorRowDetails))
                    _log.Warn("行の詳細の表示位置の更新を予約できません。");
            }
        }
        _scroll?.Refresh();
        SavedSessionsButton.IsEnabled = !_closeStarted && _store?.State.Phase == ShellPhase.Running;
        RefreshSettingsButton();
        if (!_closeStarted && _focusDeviceSelector && DeviceSelector.IsEnabled && _context is { } context &&
            !context.State.IsPending(EngineCommandName.DevicesList))
        {
            _focusDeviceSelector = false;
            if (!DeviceSelector.Focus(FocusState.Programmatic)) _log.Warn("録音デバイスの選択欄にフォーカスできません。");
        }
        try { await ShowDeviceLostNoticeAsync(); }
        catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
    }

    private void OnWindowDetailsClick(object sender, RoutedEventArgs args) =>
        WindowFailureScroller.Visibility = WindowDetailsToggle.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

    private void OnEngineDetailsClick(object sender, RoutedEventArgs args) =>
        EngineFailureScroller.Visibility = EngineDetailsToggle.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

    private long _rowDetailsRequest;
    private bool _rowDetailsReading;
    private Flyout? _rowDetailsFlyout;
    private EngineTranscriptPage? _rowDetailsTail;
    private string? _rowDetailsRowID;
    private StackPanel? _rowDetailsContent;

    private async void OnRowTimeClick(object sender, RoutedEventArgs args)
    {
        if (_closeStarted) return;
        try
        {
            var button = sender as Button ?? throw new InvalidOperationException("時刻ボタンを利用できません。");
            var row = button.DataContext as ShellTranscriptRowViewModel ?? throw new InvalidOperationException("文字起こしの行を利用できません。");
            var live = _live ?? throw new InvalidOperationException("文字起こし画面を利用できません。");
            var previousFlyout = _rowDetailsFlyout;
            _rowDetailsFlyout = null;
            previousFlyout?.Hide();
            var content = new StackPanel { Spacing = 4, MaxWidth = 400, RequestedTheme = Root.ActualTheme };
            var flyout = new Flyout { Content = content, Placement = Microsoft.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.Right };
            _rowDetailsFlyout = flyout;
            _rowDetailsTail = live.Transcript.Tail;
            _rowDetailsRowID = row.RowID;
            _rowDetailsContent = content;
            ++_rowDetailsRequest;
            ShowRowDetailsLoading(content);
            flyout.Closed += (_, _) =>
            {
                if (ReferenceEquals(_rowDetailsFlyout, flyout))
                {
                    _rowDetailsFlyout = null; _rowDetailsTail = null; _rowDetailsRowID = null;
                    _rowDetailsContent = null; ++_rowDetailsRequest;
                }
            };
            flyout.ShowAt(button);
            await RefreshRowDetailsAsync();
        }
        catch (Exception exception) { await ReportFailureAsync(exception); }
    }

    private void ReanchorRowDetails()
    {
        if (_closeStarted || _rowDetailsFlyout is not { } flyout || _rowDetailsRowID is not { } rowID || _live is not { } live) return;
        var row = live.Rows.FirstOrDefault(candidate => candidate.RowID == rowID);
        var button = row is not null && TranscriptList.ContainerFromItem(row) is ListViewItem container
            ? FindDescendant<Button>(container) : null;
        // A row virtualized out of view has no anchor; close like a transient Mac popover.
        if (button is null) { flyout.Hide(); return; }
        if (!ReferenceEquals(flyout.Target, button)) flyout.ShowAt(button);
    }

    private static T? FindDescendant<T>(DependencyObject parent) where T : DependencyObject
    {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(parent); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(parent, i);
            if (child is T match) return match;
            if (FindDescendant<T>(child) is { } nested) return nested;
        }
        return null;
    }

    private static void ShowRowDetailsLoading(StackPanel content)
    {
        content.Children.Clear();
        var ring = new ProgressRing { IsActive = true, Width = 16, Height = 16 };
        AutomationProperties.SetName(ring, "行の詳細を読み込み中");
        content.Children.Add(ring);
    }

    private async Task RefreshRowDetailsAsync()
    {
        // The store is revision-strict and admits one request at a time. While it is pending,
        // retain the latest row/revision intent and service it immediately after completion.
        if (_rowDetailsReading) return;
        _rowDetailsReading = true;
        try
        {
            while (!_closeStarted && _rowDetailsFlyout is not null && _rowDetailsRowID is { } rowID &&
                _rowDetailsContent is { } content && _live is { } live)
            {
                var request = _rowDetailsRequest;
                var requestedTail = _store?.State.Transcript.Tail;
                var details = await live.ReadRowDetailsAsync(rowID);
                if (request != _rowDetailsRequest) continue;
                if (_closeStarted || _rowDetailsFlyout is null) return;
                if (details is null)
                {
                    // A newer tail is on its way and its refresh re-requests; keep the last details until then.
                    if (!ReferenceEquals(_store?.State.Transcript.Tail, requestedTail)) return;
                    ShowRowDetailsFailure(content);
                    return;
                }
                content.Children.Clear();
                content.Children.Add(RowDetailsCaption(details.ClauseStateText));
                if (details.SpeakerTexts.Length > 0)
                {
                    content.Children.Add(RowDetailsCaption("話者区間", true));
                    foreach (var text in details.SpeakerTexts)
                    {
                        var span = RowDetailsCaption(text);
                        Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(span, Microsoft.UI.Xaml.FontNumeralAlignment.Tabular);
                        content.Children.Add(span);
                    }
                }
                return;
            }
        }
        catch (Exception exception)
        {
            if (_rowDetailsContent is { } content) ShowRowDetailsFailure(content);
            await ReportFailureAsync(exception);
        }
        finally { _rowDetailsReading = false; }
    }

    private static void ShowRowDetailsFailure(StackPanel content)
    {
        content.Children.Clear();
        content.Children.Add(RowDetailsCaption("詳細を取得できませんでした。"));
    }

    private static TextBlock RowDetailsCaption(string text, bool strong = false) => new()
    {
        Text = text, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        Style = (Style)Application.Current.Resources[strong ? "SecondaryCaptionStrong" : "SecondaryCaption"]
    };

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
            await (_store ?? throw new InvalidOperationException("The shell store is unavailable.")).SetSessionsVisibleAsync(true);
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
            var dialog = new SettingsDialog(context, settings, diagnostics, new WindowsPathPicker(this), _log.Directory, _log.Path, new ExplorerFolderRevealer()) { XamlRoot = Root.XamlRoot };
            _settingsDialog = dialog; SettingsButton.IsEnabled = false; await dialog.ShowAsync();
        }
        catch (Exception exception) { await ReportFailureAsync(exception); }
        finally
        {
            if (_settingsDialog is { } dialog) { dialog.Dispose(); _settingsDialog = null; }
            RefreshSettingsButton();
            if (!_closeStarted && SettingsButton.IsEnabled && !SettingsButton.Focus(FocusState.Programmatic))
                _log.Warn("設定にフォーカスできません。");
            try { await ShowDeviceLostNoticeAsync(); }
            catch (Exception exception) { ShowFailure(exception, _client?.Failure); }
        }
    }

    private void RefreshSettingsButton() => SettingsButton.IsEnabled = !_closeStarted && _settingsDialog is null && !_deviceLostDialogInFlight &&
        _context is { State.Capabilities: not null } && _store is
        { Initialization.IsCompleted: true, State: { Capabilities: not null, Phase: ShellPhase.Running or ShellPhase.EngineFailed } };

    private async void OnSavedSessionsClosed(object sender, WindowEventArgs args)
    {
        var window = sender as Window ?? throw new InvalidOperationException("The closed saved sessions window is unavailable.");
        window.Closed -= OnSavedSessionsClosed;
        _savedSessionsWindow = null;
        try { await (_store ?? throw new InvalidOperationException("The shell store is unavailable.")).SetSessionsVisibleAsync(false); }
        catch (ObjectDisposedException) when (_store?.State.Phase == ShellPhase.Disposed) { }
        catch (Exception exception) { await ReportFailureAsync(exception); }
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
        _log.Error("window failure: " + exception + (snapshot is null ? "" : $"\n{snapshot.Message}\nexit code: {snapshot.ExitCode?.ToString() ?? "unknown"}"));
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
        WindowFailure.Text = text.ToString();
        WindowFailureSummary.Text = FirstLineConverter.FirstLine(exception.Message);
        WindowFailureRegion.Visibility = Visibility.Visible;
    }

    private async void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowFinalClose) return;
        args.Cancel = true;
        if (_closeStarted) return;
        _closeStarted = true; Root.IsHitTestVisible = false;
        ++_rowDetailsRequest;
        _rowDetailsFlyout?.Hide();
        _log.Info("shutdown started");
        Toolbar.IsEnabled = false; SavedSessionsButton.IsEnabled = false; ReturnToLatestButton.IsEnabled = false;
        ClosingStatus.Visibility = Visibility.Visible;
        try { await ShutDownAsync(); }
        catch (Exception exception)
        {
            ShowFailure(exception, _client?.Failure);
            RestoreWindowAfterCloseFailure();
        }
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
            if (client.ProcessExitCode is int exitCode)
            {
                _log.Info($"window closed after engine had already exited (exit code {exitCode})");
                _ = closeTask.ContinueWith(task => _log.Error("engine close failed after exit: " + task.Exception), TaskContinuationOptions.OnlyOnFaulted);
                FinalClose();
                return;
            }

            try { await closeTask.WaitAsync(TimeSpan.FromSeconds(60)); FinalClose(); return; }
            catch (Exception) when (client.ProcessExitCode is int)
            {
                continue;
            }
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
                ContentDialogResult choice;
                try { choice = await dialog.ShowAsync(); }
                finally { Root.IsHitTestVisible = false; }
                if (choice == ContentDialogResult.Secondary)
                {
                    try { client.ForceKill(); await client.Completion; }
                    catch (Exception forceKillFailure)
                    {
                        ShowFailure(forceKillFailure, client.Failure);
                        continue;
                    }
                    FinalClose(); return;
                }
                if (closeTask.IsCompleted)
                {
                    try { await client.Completion.WaitAsync(TimeSpan.FromSeconds(60)); FinalClose(); return; }
                    catch (Exception waitFailure) { ShowFailure(waitFailure, client.Failure); }
                }
            }
        }
    }

    private void RestoreWindowAfterCloseFailure()
    {
        _closeStarted = false;
        Root.IsHitTestVisible = true;
        Toolbar.IsEnabled = true;
        SavedSessionsButton.IsEnabled = _store?.State.Phase == ShellPhase.Running;
        ReturnToLatestButton.IsEnabled = true;
        RefreshSettingsButton();
        ClosingStatus.Visibility = Visibility.Collapsed;
    }

    private void FinalClose()
    {
        _log.Info("shutdown finished");
        _allowFinalClose = true;
        if (_appWindow is not null) _appWindow.Closing -= OnAppWindowClosing;
        Close();
    }
}
