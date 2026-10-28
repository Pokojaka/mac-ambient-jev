using System.Globalization;
using System.Text;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace MacAmbientJev.WinUI;
internal sealed class SettingsDialog : ContentDialog, IDisposable
{
    private readonly ShellUiContext _context;
    private readonly SettingsViewModel _settings;
    private readonly DiagnosticsViewModel _diagnostics;
    private readonly IPathPicker _pathPicker;
    private readonly EngineCapabilities _capabilities;
    private readonly ComboBox _schema = Box(), _source = Box(), _device = Box(), _asr = Box(), _provider = Box(), _threads = Box();
    private readonly ComboBox _lowHeat = Box(), _decisions = Box(), _autoExport = Box(), _exportPath = Box();
    private readonly Button _save = new() { Content = "保存" }, _reload = new() { Content = "再読み込み", Visibility = Visibility.Collapsed };
    private readonly Button _privacy = new() { Content = "マイクのプライバシー設定を開く" }, _prepare = new() { Content = "モデルを準備" };
    private readonly Button _pickExport = new() { Content = "フォルダを選択…" };
    private readonly Button _refresh = new() { Content = "利用状況を更新" }, _inspect = new() { Content = "モデルを確認" };
    private readonly TextBlock _generalError = Text(), _diagnosticError = Text(), _usage = Text(), _models = Text(), _transport = Text(), _preparation = Text("状態: 未取得"), _exportCurrent = Text();
    private readonly ProgressRing _settingsProgress = Ring(), _modelsProgress = Ring(), _usageProgress = Ring();
    private readonly MicrophonePrivacyLauncher _privacyLauncher = new();
    private EngineDevicesResult? _deviceResult;
    private EngineSource? _deviceSource, _deferredDeviceSource;
    private bool _deferredDeviceForce, _hydrating, _disposed, _loadingDevices, _privacyPending, _pickerPending, _reloadRunning, _commitRunning, _prepareRunning, _draftPostPending;
    private int _editVersion;
    private string? _localError;
    public SettingsDialog(ShellUiContext context, SettingsViewModel settings, DiagnosticsViewModel diagnostics, IPathPicker pathPicker) {
        DefaultStyleKey = typeof(ContentDialog);
        _context = context ?? throw new ArgumentNullException(nameof(context)); _settings = settings ?? throw new ArgumentNullException(nameof(settings));
        _diagnostics = diagnostics ?? throw new ArgumentNullException(nameof(diagnostics)); _pathPicker = pathPicker ?? throw new ArgumentNullException(nameof(pathPicker));
        _capabilities = settings.Capabilities ?? throw new InvalidOperationException("Engine capabilities are unavailable.");
        Title = "設定"; CloseButtonText = "閉じる"; MaxWidth = 620; BuildChoices();
        var general = new StackPanel { Spacing = 8 };
        AddField(general, "設定スキーマ", _schema); AddField(general, "録音元", _source); AddField(general, "デバイス", _device);
        general.Children.Add(Text("マイクの音が入らないときは、Windows の［設定］→［プライバシーとセキュリティ］→［マイク］で「マイク アクセス」と「デスクトップ アプリにマイクへのアクセスを許可する」をオンにしてください。"));
        general.Children.Add(_privacy); general.Children.Add(Text("入力音量の自動調整: " + (_settings.AutomaticInputVolume ?? throw new InvalidOperationException("Capability is unavailable."))));
        general.Children.Add(Text("熱監視: " + (_settings.ThermalMonitoring ?? throw new InvalidOperationException("Capability is unavailable."))));
        AddField(general, "音声認識モデル", _asr); AddField(general, "実行プロバイダー", _provider); AddField(general, "スレッド数", _threads);
        AddField(general, "低発熱ペーシング", _lowHeat); AddField(general, "発話文の判定", _decisions); AddField(general, "処理完了後に自動で書き出す", _autoExport);
        AddField(general, "書き出し先", _exportPath); general.Children.Add(_exportCurrent);
        general.Children.Add(_pickExport); general.Children.Add(Text("保存先 / 録音データ: LocalAppData/mac-ambient-jev/sessions（固定）"));
        general.Children.Add(_settingsProgress); general.Children.Add(_prepare); general.Children.Add(_preparation); general.Children.Add(_generalError); general.Children.Add(_reload); general.Children.Add(_save);
        var diag = new StackPanel { Spacing = 8 }; _refresh.Content = _diagnostics.RefreshLabel; _inspect.Content = _diagnostics.InspectModelsLabel;
        _refresh.Click += OnRefresh; _inspect.Click += OnInspect; diag.Children.Add(_refresh); diag.Children.Add(_usageProgress); diag.Children.Add(_usage); diag.Children.Add(_inspect);
        diag.Children.Add(_modelsProgress); diag.Children.Add(_models); diag.Children.Add(Text("エンジン / トランスポート")); diag.Children.Add(_transport); diag.Children.Add(_diagnosticError);
        var tabs = new TabView { IsAddTabButtonVisible = false, CanReorderTabs = false, MaxWidth = 620 };
        tabs.TabItems.Add(new TabViewItem { Header = "一般", Content = View(general), IsClosable = false }); tabs.TabItems.Add(new TabViewItem { Header = "診断", Content = View(diag), IsClosable = false }); Content = tabs; Hydrate(context.Store.State.SettingsDraft);
        _schema.SelectionChanged += OnDraftChanged; _source.SelectionChanged += OnSourceChanged; _device.SelectionChanged += OnDraftChanged; _asr.SelectionChanged += OnDraftChanged;
        _provider.SelectionChanged += OnDraftChanged; _threads.SelectionChanged += OnDraftChanged; _lowHeat.SelectionChanged += OnDraftChanged; _decisions.SelectionChanged += OnDraftChanged;
        _autoExport.SelectionChanged += OnDraftChanged; _exportPath.SelectionChanged += OnDraftChanged; _save.Click += OnSave; _reload.Click += OnReload; _privacy.Click += OnPrivacy; _prepare.Click += OnPrepare; _pickExport.Click += OnPickExport;
        ToolTipService.SetToolTip(_source, "録音元を選択すると、その録音元のデバイス一覧を更新します。"); ToolTipService.SetToolTip(_device, "既定のデバイスまたは一覧にあるデバイスを明示的に選択します。");
        ToolTipService.SetToolTip(_save, "全項目を選択してください。録音中または処理中は設定を保存できません。"); context.Refreshed += OnRefreshed; UpdateViews();
        if (SelectedSource() is EngineSource source && context.Store.State.Devices?.Source != source) _ = LoadDevicesAsync(source, false);
    }
    private static ComboBox Box() => new() { SelectedIndex = -1 };
    private static ProgressRing Ring() => new() { IsActive = false, Visibility = Visibility.Collapsed };
    private static TextBlock Text(string value = "") => new() { Text = value, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true };
    private static ScrollViewer View(UIElement content) => new() { Content = content, MaxHeight = 460, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private static void AddField(Panel panel, string label, ComboBox box) { panel.Children.Add(Text(label)); panel.Children.Add(box); }
    private static void Add(ComboBox box, object? value, string label) => box.Items.Add(new ComboBoxItem { Content = label, Tag = value });
    private static void Select(ComboBox box, object? value) { box.SelectedIndex = -1; for (var i = 0; i < box.Items.Count; i++) if (Equals(((ComboBoxItem)box.Items[i]).Tag, value)) { box.SelectedIndex = i; return; } }
    private void BuildChoices() {
        Add(_schema, 1L, "1"); foreach (var value in _capabilities.Sources) Add(_source, value, value switch { EngineSource.Microphone => "マイク", EngineSource.SystemAudio => "システム音声", _ => throw new InvalidOperationException($"Unknown source: {value}.") });
        foreach (var value in _capabilities.AsrSizes) Add(_asr, value, value switch { EngineASRSize.Large => "1.7B", EngineASRSize.Small => "0.6B", _ => throw new InvalidOperationException($"Unknown ASR size: {value}.") });
        foreach (var value in _capabilities.ExecutionProviders) Add(_provider, value, value switch { EngineExecutionProvider.Cpu => "CPU", _ => throw new InvalidOperationException($"Unknown provider: {value}.") });
        if (_capabilities.MaximumThreads is < 1 or > 4) throw new InvalidOperationException("Engine maximum thread capability is invalid.");
        for (long i = 1; i <= _capabilities.MaximumThreads; i++) Add(_threads, i, i.ToString(CultureInfo.InvariantCulture));
        foreach (var box in new[] { _lowHeat, _decisions, _autoExport }) { Add(box, true, "オン"); Add(box, false, "オフ"); }
    }
    private void Hydrate(EngineSettings? value) {
        var wasHydrating = _hydrating; _hydrating = true;
        try {
            foreach (var box in new[] { _schema, _source, _device, _asr, _provider, _threads, _lowHeat, _decisions, _autoExport, _exportPath }) box.SelectedIndex = -1;
            SetDevices(value?.Source, value?.Device); SetExportChoices(value?.ExportDestinationPath, value is not null);
            if (value is not null)
            {
                Select(_schema, value.SchemaVersion); Select(_source, value.Source); Select(_device, value.Device); Select(_asr, value.AsrSize);
                Select(_provider, value.ExecutionProvider); Select(_threads, value.Threads); Select(_lowHeat, value.LowHeat); Select(_decisions, value.DecisionsEnabled);
                Select(_autoExport, value.AutomaticExport); Select(_exportPath, value.ExportDestinationPath);
                if (new[] { _schema, _source, _device, _asr, _provider, _threads, _lowHeat, _decisions, _autoExport, _exportPath }.Any(box => box.SelectedIndex < 0))
                    throw new InvalidOperationException("Settings draft contains a choice unavailable in current capabilities.");
            }
        } finally { _hydrating = wasHydrating; }
        UpdateViews();
    }
    private void SetExportChoices(string? path, bool selected) {
        _exportPath.Items.Clear(); Add(_exportPath, null, "なし"); if (path is not null) Add(_exportPath, path, path);
        if (selected) Select(_exportPath, path); else _exportPath.SelectedIndex = -1;
        _exportCurrent.Text = "書き出し先: " + (selected ? path ?? "なし" : "未選択");
    }
    private void SetDevices(EngineSource? source, EngineDevice? selected) {
        var wasHydrating = _hydrating; _hydrating = true;
        try {
            _device.Items.Clear(); Add(_device, new EngineDevice.Default(), "既定のデバイス"); var result = _context.Store.State.Devices;
            if (source is EngineSource selectedSource && result?.Source == selectedSource)
                foreach (var info in result.Devices ?? throw new InvalidOperationException("Device list is missing.")) Add(_device, new EngineDevice.Id(info.ID), info.Name);
            if (selected is EngineDevice.Id saved && !_device.Items.Cast<ComboBoxItem>().Any(item => Equals(item.Tag, saved))) Add(_device, saved, saved.ID);
            _deviceResult = result; _deviceSource = source; Select(_device, selected);
        } finally { _hydrating = wasHydrating; }
    }
    private EngineSource? SelectedSource() => (_source.SelectedItem as ComboBoxItem)?.Tag is EngineSource value ? value : null;
    private EngineDevice? SelectedDevice() => (_device.SelectedItem as ComboBoxItem)?.Tag as EngineDevice;
    private static T? Value<T>(ComboBox box) where T : struct => (box.SelectedItem as ComboBoxItem)?.Tag is T value ? value : null;
    private async void OnDraftChanged(object sender, SelectionChangedEventArgs args) {
        try { if (!_hydrating && !_disposed) await ApplyDraftAsync(); }
        catch (Exception error) { ReportError(error); }
    }
    private async void OnSourceChanged(object sender, SelectionChangedEventArgs args) {
        try {
            if (_hydrating || _disposed) return;
            _hydrating = true; _device.SelectedIndex = -1; SetDevices(SelectedSource(), null); _hydrating = false; await ApplyDraftAsync();
            if (!_disposed && SelectedSource() is EngineSource source) await LoadDevicesAsync(source, true);
        } catch (Exception error) { _hydrating = false; ReportError(error); }
    }
    private async Task ApplyDraftAsync() {
        var version = ++_editVersion; _draftPostPending = true; _save.IsEnabled = false;
        var export = _exportPath.SelectedItem as ComboBoxItem; _exportCurrent.Text = "書き出し先: " + (export is null ? "未選択" : export.Tag as string ?? "なし");
        EngineSettings? draft = null;
        try
        {
            draft = SettingsViewModel.CreateDraft(Value<long>(_schema), SelectedSource(), SelectedDevice(), Value<EngineASRSize>(_asr), Value<EngineExecutionProvider>(_provider),
                Value<long>(_threads), Value<bool>(_lowHeat), Value<bool>(_decisions), Value<bool>(_autoExport), export is not null, export?.Tag as string);
            if (draft is not null) _localError = null;
        }
        catch (Exception error) { ReportError(error); }
        try { await _settings.EditDraftAsync(draft); } catch (Exception error) { ReportError(error); }
        if (_disposed || version != _editVersion) return;
        _draftPostPending = false; UpdateViews();
    }
    private async Task LoadDevicesAsync(EngineSource source, bool force) {
        try
        {
            var state = _context.Store.State;
            if (!force && state.Devices?.Source == source) { SetDevices(source, SelectedDevice()); return; }
            if (_loadingDevices || state.IsPending(EngineCommandName.DevicesList)) { _deferredDeviceSource = source; _deferredDeviceForce |= force; UpdateViews(); return; }
            _deferredDeviceSource = null; _deferredDeviceForce = false; _loadingDevices = true; UpdateViews(); await _context.Store.ReloadDevicesAsync(source);
            if (!_disposed && source == SelectedSource()) SetDevices(source, SelectedDevice());
        }
        catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _loadingDevices = false; try { UpdateViews(); StartDeferredDevicesIfReady(); } catch (Exception error) { ReportError(error); } } }
    }
    private void StartDeferredDevicesIfReady()
    {
        if (_deferredDeviceSource is not EngineSource source || source != SelectedSource() || _context.Store.State.IsPending(EngineCommandName.DevicesList)) return;
        var force = _deferredDeviceForce; _deferredDeviceSource = null; _deferredDeviceForce = false; _ = LoadDevicesAsync(source, force);
    }
    private void OnRefreshed(object? sender, EventArgs args) {
        if (_disposed) return;
        try {
            var source = SelectedSource(); var state = _context.Store.State;
            if (_deviceSource != source || !ReferenceEquals(_deviceResult, state.Devices)) SetDevices(source, SelectedDevice());
            StartDeferredDevicesIfReady(); UpdateViews();
        } catch (Exception error) { ReportError(error); }
    }
    private void UpdateViews() {
        if (_disposed) return;
        var state = _context.Store.State; var pending = state.IsPending(EngineCommandName.SettingsGet) || state.IsPending(EngineCommandName.SettingsReplace) || state.IsPending(EngineCommandName.ModelsPrepare);
        _settingsProgress.IsActive = pending; _settingsProgress.Visibility = pending ? Visibility.Visible : Visibility.Collapsed;
        var locked = _loadingDevices || state.IsPending(EngineCommandName.DevicesList); _source.IsEnabled = !locked; _device.IsEnabled = !locked; _reload.Visibility = state.SettingsConflict ? Visibility.Visible : Visibility.Collapsed;
        _save.IsEnabled = !_draftPostPending && !pending && !locked && !_commitRunning && !_reloadRunning && !_pickerPending && _settings.Commit.CanExecute(null) && state.SettingsDraft is not null;
        _reload.IsEnabled = !_reloadRunning && !_commitRunning && !_prepareRunning && !_pickerPending && _settings.Reload.CanExecute(null); _privacy.IsEnabled = !_privacyPending;
        _pickExport.IsEnabled = !_disposed && state.Phase == ShellPhase.Running && !_pickerPending && !_commitRunning && !_reloadRunning && !_prepareRunning && !_draftPostPending;
        _prepare.IsEnabled = !_prepareRunning && !_commitRunning && !_reloadRunning && _settings.PrepareModels.CanExecute(null); _refresh.IsEnabled = _diagnostics.Refresh.CanExecute(null); _inspect.IsEnabled = _diagnostics.InspectModels.CanExecute(null);
        var errors = new List<string>(); if (_localError is not null) errors.Add(_localError); if (state.SettingsConflict) errors.Add("設定が変更されています。再読み込みしてください。");
        if (state.LastError is not null) errors.Add(state.LastError.Code + ": " + state.LastError.Message); if (state.CommandError is not null) errors.Add(state.CommandError); if (state.StoreFailure is not null) errors.Add(state.StoreFailure);
        Show(_generalError, string.Join(Environment.NewLine, errors)); _preparation.Text = "状態: " + (state.Engine?.Presentation.PreparationStatusText ?? "未取得");
        _usageProgress.IsActive = _diagnostics.IsLoading; _usageProgress.Visibility = _diagnostics.IsLoading ? Visibility.Visible : Visibility.Collapsed;
        _modelsProgress.IsActive = _diagnostics.IsInspectingModels; _modelsProgress.Visibility = _diagnostics.IsInspectingModels ? Visibility.Visible : Visibility.Collapsed;
        _usage.Text = _diagnostics.IsLoading ? "" : FormatUsage(); _models.Text = _diagnostics.IsInspectingModels ? "" : FormatModels(); _transport.Text = FormatTransport();
        errors.Clear(); if (_localError is not null) errors.Add(_localError); if (!_diagnostics.IsLoading && _diagnostics.UsageError is { } usageError) errors.Add(usageError.Code + ": " + usageError.Message);
        if (_diagnostics.LastError is { } last) errors.Add(last.Code + ": " + last.Message); if (_diagnostics.CommandError is not null) errors.Add(_diagnostics.CommandError);
        if (_diagnostics.StoreFailure is not null) errors.Add(_diagnostics.StoreFailure); Show(_diagnosticError, string.Join(Environment.NewLine, errors));
    }
    private static void Show(TextBlock block, string value) { block.Text = value; block.Visibility = value.Length == 0 ? Visibility.Collapsed : Visibility.Visible; }
    private void ReportError(Exception error) {
        if (_disposed) return; _localError = error.Message; Show(_generalError, _localError); Show(_diagnosticError, _localError);
    }
    private string FormatUsage() {
        var result = _diagnostics.Diagnostics; if (result is null) return "未取得";
        var scope = result.Scope switch { EngineDiagnosticsScope.EngineProcess => "現在のエンジンプロセス", _ => throw new InvalidOperationException($"Unknown diagnostics scope: {result.Scope}.") };
        var usage = _diagnostics.Usage; var title = _diagnostics.UsageTitle;
        if (_diagnostics.UsageError is { } error) return $"{scope}{Environment.NewLine}{title}{Environment.NewLine}エラー: {error.Code}: {error.Message}";
        if (usage is null) return $"{scope}{Environment.NewLine}{title}{Environment.NewLine}未取得";
        var text = new StringBuilder().Append(scope).AppendLine().AppendLine(title); AppendUsage(text, usage.SendCount, usage.InputTokens, usage.SuccessCount, usage.FailureCount, true);
        text.AppendLine("境界判定リクエスト"); AppendUsage(text, usage.BoundaryRequests.SendCount, usage.BoundaryRequests.InputTokens, usage.BoundaryRequests.SuccessCount, usage.BoundaryRequests.FailureCount, false);
        text.AppendLine("優先度判定リクエスト"); AppendUsage(text, usage.PriorityRequests.SendCount, usage.PriorityRequests.InputTokens, usage.PriorityRequests.SuccessCount, usage.PriorityRequests.FailureCount, false);
        text.AppendLine("保留").Append("境界判定の保留区間: ").Append(usage.PendingBoundarySegmentCount.ToString(CultureInfo.InvariantCulture)).AppendLine();
        return text.Append("優先度判定の保留発話文: ").Append(usage.PendingPriorityClauseCount.ToString(CultureInfo.InvariantCulture)).ToString();
    }
    private static void AppendUsage(StringBuilder text, long sends, long tokens, long success, long failure, bool total) {
        text.Append(total ? "リクエスト回数（合計）: " : "リクエスト回数: ").Append(sends.ToString(CultureInfo.InvariantCulture)).AppendLine();
        text.Append("入力 token 数: ").Append(tokens.ToString(CultureInfo.InvariantCulture)).AppendLine();
        text.Append("成功件数: ").Append(success.ToString(CultureInfo.InvariantCulture)).AppendLine(); text.Append("失敗件数: ").Append(failure.ToString(CultureInfo.InvariantCulture)).AppendLine();
    }
    private string FormatModels() {
        var inspection = _diagnostics.ModelsInspection; if (inspection is null) return "未取得";
        return inspection.ClauseTagger switch {
            EngineClauseTaggerInspection.Invalid invalid => "エラー: " + invalid.Error.Code + ": " + invalid.Error.Message,
            EngineClauseTaggerInspection.Validated valid => $"Backend: {valid.Identity.Backend}{Environment.NewLine}ModelID: {valid.Identity.ModelID}{Environment.NewLine}Revision: {valid.Identity.Revision}{Environment.NewLine}TokenizerSHA256: {valid.Identity.TokenizerSHA256}",
            _ => throw new InvalidOperationException("Unknown clause tagger inspection.") };
    }
    private string FormatTransport() {
        var version = typeof(SettingsDialog).Assembly.GetName().Version ?? throw new InvalidOperationException("Shell assembly version is unavailable.");
        var text = new StringBuilder().Append("アプリ バージョン: ").AppendLine(version.ToString()).Append(".NET: ").AppendLine(Environment.Version.ToString()).AppendLine("NDJSON: v1");
        text.Append("終了コード: ").AppendLine(_diagnostics.EngineFailure?.ExitCode?.ToString(CultureInfo.InvariantCulture) ?? "未確定");
        if (_diagnostics.EngineFailure is { } failure) {
            text.Append("エンジン プロセス: ").AppendLine(failure.Message);
            if (failure.LastEngineError is { } error) text.Append("エンジン エラー: ").Append(error.Code).Append(": ").AppendLine(error.Message);
            text.Append("標準エラー出力（UTF-8）: ").AppendLine(Encoding.UTF8.GetString(failure.Stderr.Bytes)); text.Append("標準エラー出力の破棄バイト数: ").Append(failure.Stderr.DiscardedBytes.ToString(CultureInfo.InvariantCulture));
        }
        return text.ToString();
    }
    private async void OnSave(object sender, RoutedEventArgs args) {
        try {
            if (_disposed || _commitRunning || _reloadRunning || _prepareRunning || _pickerPending || _loadingDevices || _context.Store.State.IsPending(EngineCommandName.DevicesList) || _draftPostPending || !_settings.Commit.CanExecute(null) || _context.Store.State.SettingsDraft is null) return;
            _commitRunning = true; UpdateViews(); _settings.Commit.Execute(null); await (_settings.Commit.Execution ?? throw new InvalidOperationException("Settings commit did not start."));
            if (_disposed) return;
        }
        catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _commitRunning = false; try { UpdateViews(); } catch (Exception error) { ReportError(error); } } }
    }
    private async void OnReload(object sender, RoutedEventArgs args) {
        var before = _context.Store.State.ConfirmedSettings;
        try {
            if (_disposed || _reloadRunning || _commitRunning || _pickerPending || !_settings.Reload.CanExecute(null)) return;
            _reloadRunning = true; UpdateViews(); _settings.Reload.Execute(null); await (_settings.Reload.Execution ?? throw new InvalidOperationException("Settings reload did not start."));
            if (_disposed) return; var state = _context.Store.State;
            if (state.SettingsStatus == ShellSettingsStatus.Available && state.ConfirmedSettings is { } confirmed && !ReferenceEquals(before, confirmed) && !state.SettingsConflict) { _localError = null; Hydrate(state.SettingsDraft); }
        }
        catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _reloadRunning = false; try { UpdateViews(); } catch (Exception error) { ReportError(error); } } }
    }
    private async void OnPrepare(object sender, RoutedEventArgs args) {
        try {
            if (_disposed || _prepareRunning || _commitRunning || _reloadRunning || _pickerPending || !_settings.PrepareModels.CanExecute(null)) return;
            _prepareRunning = true; UpdateViews(); _settings.PrepareModels.Execute(null); await (_settings.PrepareModels.Execution ?? throw new InvalidOperationException("Model preparation did not start."));
            if (_disposed) return;
        }
        catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _prepareRunning = false; try { UpdateViews(); } catch (Exception error) { ReportError(error); } } }
    }
    private async void OnRefresh(object sender, RoutedEventArgs args) => await RunDiagnosticAsync(_diagnostics.Refresh);
    private async void OnInspect(object sender, RoutedEventArgs args) => await RunDiagnosticAsync(_diagnostics.InspectModels);
    private async Task RunDiagnosticAsync(ShellCommand command) {
        try { if (_disposed || !command.CanExecute(null)) return; command.Execute(null); await (command.Execution ?? throw new InvalidOperationException("Diagnostic command did not start.")); if (!_disposed) UpdateViews(); }
        catch (Exception error) { ReportError(error); }
    }
    private async void OnPickExport(object sender, RoutedEventArgs args) {
        try {
            if (_disposed || _pickerPending || _commitRunning || _reloadRunning || _prepareRunning || _draftPostPending || _context.Store.State.Phase != ShellPhase.Running) return;
            _pickerPending = true; UpdateViews(); var path = await _pathPicker.PickExportFolderAsync();
            if (_disposed || path is null) return;
            var wasHydrating = _hydrating; _hydrating = true;
            try { SetExportChoices(path, true); } finally { _hydrating = wasHydrating; }
            await ApplyDraftAsync();
        } catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _pickerPending = false; try { UpdateViews(); } catch (Exception error) { ReportError(error); } } }
    }
    private async void OnPrivacy(object sender, RoutedEventArgs args) {
        try { if (_disposed || _privacyPending) return; _privacyPending = true; UpdateViews(); await _privacyLauncher.OpenAsync(); if (!_disposed) _localError = null; }
        catch (Exception error) { ReportError(error); }
        finally { if (!_disposed) { _privacyPending = false; try { UpdateViews(); } catch (Exception error) { ReportError(error); } } }
    }
    public void Dispose() {
        if (_disposed) return; _disposed = true; _context.Refreshed -= OnRefreshed;
        _schema.SelectionChanged -= OnDraftChanged; _source.SelectionChanged -= OnSourceChanged; _device.SelectionChanged -= OnDraftChanged; _asr.SelectionChanged -= OnDraftChanged;
        _provider.SelectionChanged -= OnDraftChanged; _threads.SelectionChanged -= OnDraftChanged; _lowHeat.SelectionChanged -= OnDraftChanged; _decisions.SelectionChanged -= OnDraftChanged; _autoExport.SelectionChanged -= OnDraftChanged; _exportPath.SelectionChanged -= OnDraftChanged;
        _save.Click -= OnSave; _reload.Click -= OnReload; _privacy.Click -= OnPrivacy; _prepare.Click -= OnPrepare; _pickExport.Click -= OnPickExport; _refresh.Click -= OnRefresh; _inspect.Click -= OnInspect;
    }
}
