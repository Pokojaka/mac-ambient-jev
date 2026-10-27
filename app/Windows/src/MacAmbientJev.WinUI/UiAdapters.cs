using MacAmbientJev.Presentation;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Data;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using VirtualKey = Windows.System.VirtualKey;

namespace MacAmbientJev.WinUI;

internal sealed class MicrophonePrivacyLauncher
{
    public async Task OpenAsync()
    {
        if (!await Windows.System.Launcher.LaunchUriAsync(new Uri("ms-settings:privacy-microphone")))
            throw new InvalidOperationException("マイクのプライバシー設定を開けませんでした。");
    }
}

internal sealed class DispatcherQueueUiDispatcher(DispatcherQueue queue) : IUiDispatcher
{
    public bool TryEnqueue(Action callback) => queue.TryEnqueue(() => callback());
}

public sealed class VisibilityConverter : IValueConverter
{
    public object Convert(object? value, Type targetType, object? parameter, string language)
    {
        if (targetType != typeof(Visibility)) throw new ArgumentException("Visibility is the only supported target type.", nameof(targetType));
        var invert = parameter switch { null => false, "Invert" => true, _ => throw new ArgumentException("Parameter must be null or 'Invert'.", nameof(parameter)) };
        var visible = value switch { bool boolean => boolean, string text => text.Length != 0, null => false,
            _ => throw new ArgumentException("Value must be a Boolean, string, or null.", nameof(value)) };
        return visible != invert ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object? value, Type targetType, object? parameter, string language) => throw new NotSupportedException();
}

internal sealed class TranscriptScrollAdapter : IDisposable
{
    private readonly ListView _list;
    private readonly LiveViewModel _live;
    private readonly Func<Exception, Task> _reportFailure;
    private readonly List<ScrollBar> _scrollBars = [];
    private ScrollViewer? _viewer;
    private bool _disposed, _loaded, _scrollPending, _scrollRunning, _locallyPaused, _wasFollowing;
    private bool _returnToLatestPending, _returnAnimationRunning;
    private double _returnStartOffset;
    private readonly System.Diagnostics.Stopwatch _returnAnimationClock = new();

    public TranscriptScrollAdapter(ListView list, LiveViewModel live, Func<Exception, Task> reportFailure)
    {
        _list = list ?? throw new ArgumentNullException(nameof(list)); _live = live ?? throw new ArgumentNullException(nameof(live));
        _reportFailure = reportFailure ?? throw new ArgumentNullException(nameof(reportFailure)); _wasFollowing = live.IsFollowing;
        list.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(OnPointerWheelChanged), true);
        list.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown), true); list.Loaded += OnLoaded;
    }

    public void Refresh()
    {
        if (_disposed) return;
        var following = _live.IsFollowing;
        if (!_wasFollowing && following) { _locallyPaused = false; _returnToLatestPending = true; }
        _wasFollowing = following;
        if (!following || _locallyPaused || _live.Rows.Count == 0) { CancelReturnAnimation(); return; }
        if (_returnToLatestPending)
        {
            if (_viewer is not null) StartReturnAnimation();
            return;
        }
        if (_returnAnimationRunning) return;
        ScrollToLatest();
    }

    private void StartReturnAnimation()
    {
        var viewer = _viewer ?? throw new InvalidOperationException("The transcript ScrollViewer is not loaded.");
        _returnToLatestPending = false;
        if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled) { ScrollToLatest(); return; }
        _returnStartOffset = viewer.VerticalOffset;
        _returnAnimationClock.Restart(); _returnAnimationRunning = true;
        CompositionTarget.Rendering += OnReturnAnimationRendering;
    }

    private void OnReturnAnimationRendering(object? sender, object args)
    {
        try
        {
            if (_disposed || !_live.IsFollowing || _locallyPaused || _live.Rows.Count == 0)
            { CancelReturnAnimation(); return; }
            var viewer = _viewer ?? throw new InvalidOperationException("The transcript ScrollViewer was detached during animation.");
            if (!new Windows.UI.ViewManagement.UISettings().AnimationsEnabled)
            { CancelReturnAnimation(); ScrollToLatest(); return; }
            var progress = Math.Min(_returnAnimationClock.Elapsed.TotalMilliseconds / 200, 1);
            var eased = 1 - Math.Pow(1 - progress, 3);
            viewer.ChangeView(null, _returnStartOffset + (viewer.ScrollableHeight - _returnStartOffset) * eased, null, true);
            if (progress >= 1) { CancelReturnAnimation(); ScrollToLatest(); }
        }
        catch (Exception exception) { CancelReturnAnimation(); ForwardFailure(exception); }
    }

    private void ScrollToLatest()
    {
        _list.UpdateLayout(); _list.ScrollIntoView(_live.Rows[_live.Rows.Count - 1]);
    }

    private void CancelReturnAnimation()
    {
        CompositionTarget.Rendering -= OnReturnAnimationRendering;
        _returnAnimationClock.Stop(); _returnAnimationRunning = false; _returnToLatestPending = false;
    }

    private void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_disposed || _loaded) return;
        _loaded = true; _list.Loaded -= OnLoaded;
        try
        {
            _list.ApplyTemplate(); _list.UpdateLayout();
            var nodes = VisualTree(_list).ToArray(); var viewers = nodes.OfType<ScrollViewer>().ToArray();
            if (viewers.Length != 1) throw new InvalidOperationException(viewers.Length == 0
                ? "The transcript ListView template has no ScrollViewer." : "The transcript ListView template has multiple ScrollViewers.");
            _viewer = viewers[0];
            foreach (var bar in nodes.OfType<ScrollBar>()) { bar.Scroll += OnScrollBarScroll; _scrollBars.Add(bar); }
            _viewer.DirectManipulationStarted += OnDirectManipulationStarted;
            if (_returnToLatestPending) Refresh();
        }
        catch (Exception exception) { DetachTemplateHandlers(); ForwardFailure(exception); }
    }

    private static IEnumerable<DependencyObject> VisualTree(DependencyObject node)
    {
        yield return node;
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
            foreach (var child in VisualTree(VisualTreeHelper.GetChild(node, i))) yield return child;
    }

    private void OnPointerWheelChanged(object sender, PointerRoutedEventArgs args) => RequestUserScroll();
    private void OnDirectManipulationStarted(object? sender, object args) => RequestUserScroll();
    private void OnScrollBarScroll(object sender, ScrollEventArgs args) => RequestUserScroll();
    private void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.Up or VirtualKey.Down or VirtualKey.PageUp or VirtualKey.PageDown or VirtualKey.Home or VirtualKey.End or VirtualKey.Space ||
            _viewer?.ComputedHorizontalScrollBarVisibility == Visibility.Visible && args.Key is VirtualKey.Left or VirtualKey.Right) RequestUserScroll();
    }

    private void RequestUserScroll()
    {
        if (_disposed) return;
        CancelReturnAnimation();
        _locallyPaused = true; _scrollPending = true;
        if (_scrollRunning) return;
        _scrollRunning = true; DrainUserScrollRequests();
    }

    private async void DrainUserScrollRequests()
    {
        try { while (!_disposed && _scrollPending) { _scrollPending = false; await _live.UserScrolledAsync(); } }
        catch (Exception exception) { await _reportFailure(exception); }
        finally
        {
            _scrollRunning = false;
            if (!_disposed && _scrollPending) { _scrollRunning = true; DrainUserScrollRequests(); }
        }
    }

    private async void ForwardFailure(Exception exception) => await _reportFailure(exception);
    private void DetachTemplateHandlers()
    {
        CancelReturnAnimation();
        if (_viewer is not null) _viewer.DirectManipulationStarted -= OnDirectManipulationStarted;
        foreach (var bar in _scrollBars) bar.Scroll -= OnScrollBarScroll;
        _scrollBars.Clear(); _viewer = null;
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true; _scrollPending = false;
        _list.RemoveHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler(OnPointerWheelChanged));
        _list.RemoveHandler(UIElement.KeyDownEvent, new KeyEventHandler(OnKeyDown)); _list.Loaded -= OnLoaded;
        DetachTemplateHandlers();
    }
}
