using System.ComponentModel;
using System.Windows.Input;
using MacAmbientJev.Protocol;

namespace MacAmbientJev.Presentation;

public interface IUiDispatcher { bool TryEnqueue(Action callback); }

public sealed class ShellUiContext : IDisposable
{
    private static readonly TimeSpan MinimumInterval = TimeSpan.FromMilliseconds(100);
    private readonly object _gate = new();
    private readonly ShellStore _store;
    private readonly IUiDispatcher _dispatcher;
    private readonly TimeProvider _timeProvider;
    private readonly ITimer _timer;
    private readonly List<ShellCommand> _commands = []; private ShellState _state;
    private bool _disposed, _dispatchFailed, _dirty, _scheduled, _timerArmed, _hasRendered;
    private long _lastRenderTimestamp;
    public ShellUiContext(ShellStore store, IUiDispatcher dispatcher, TimeProvider timeProvider)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store)); _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _timeProvider = timeProvider ?? throw new ArgumentNullException(nameof(timeProvider));
        _state = store.State;
        _timer = timeProvider.CreateTimer(TimerElapsed, null, Timeout.InfiniteTimeSpan, Timeout.InfiniteTimeSpan);
        store.Changed += StoreChanged;
        if (!ReferenceEquals(_state, store.State)) RequestRefresh();
    }
    public ShellStore Store => _store; public ShellState State => Volatile.Read(ref _state);
    public event EventHandler? Refreshed;
    internal bool IsActive { get { lock (_gate) return ActiveLocked; } }
    private bool ActiveLocked => !_disposed && !_dispatchFailed;
    private void StoreChanged(object? sender, EventArgs args) => RequestRefresh();
    public void RequestRefresh()
    {
        bool enqueue;
        lock (_gate) { if (!ActiveLocked) return; _dirty = true; enqueue = ScheduleIfReadyLocked(); } if (enqueue) EnqueueScheduled();
    }
    internal ShellCommand Command(Func<object?, bool> canExecute, Func<object?, Task> execute)
    {
        var command = new ShellCommand(this, canExecute, execute);
        lock (_gate) { if (!ActiveLocked) throw new ObjectDisposedException(nameof(ShellUiContext)); _commands.Add(command); }
        return command;
    }
    private bool ScheduleIfReadyLocked()
    {
        if (_scheduled) return false;
        if (!_hasRendered || _timeProvider.GetElapsedTime(_lastRenderTimestamp, _timeProvider.GetTimestamp()) >= MinimumInterval)
        { _scheduled = true; return true; }
        ArmTimerLocked(); return false;
    }
    private void ArmTimerLocked()
    {
        if (_timerArmed) return;
        var elapsed = _timeProvider.GetElapsedTime(_lastRenderTimestamp, _timeProvider.GetTimestamp());
        var delay = MinimumInterval - elapsed;
        _timerArmed = true;
        try { _timer.Change(delay > TimeSpan.Zero ? delay : TimeSpan.Zero, Timeout.InfiniteTimeSpan); }
        catch { _timerArmed = false; throw; }
    }
    private void TimerElapsed(object? state)
    {
        bool enqueue;
        lock (_gate) { _timerArmed = false; if (!ActiveLocked || !_dirty || _scheduled) return; enqueue = ScheduleIfReadyLocked(); } if (enqueue) EnqueueScheduled();
    }
    private void EnqueueScheduled()
    {
        try { if (_dispatcher.TryEnqueue(RefreshOnUiThread)) return; }
        catch (Exception exception) { StopAfterDispatchFailure(new InvalidOperationException("UI dispatcher rejected the refresh.", exception)); return; }
        StopAfterDispatchFailure(new InvalidOperationException("UI dispatcher rejected the refresh."));
    }
    private void StopAfterDispatchFailure(Exception exception)
    {
        lock (_gate) { if (!ActiveLocked) return; _dispatchFailed = true; _scheduled = false; _dirty = false; _timerArmed = false; }
        ReportFailure(exception);
    }
    private void RefreshOnUiThread()
    {
        EventHandler? refreshed;
        ShellCommand[] commands;
        lock (_gate)
        {
            if (!ActiveLocked) return;
            Volatile.Write(ref _state, _store.State);
            _dirty = false; _lastRenderTimestamp = _timeProvider.GetTimestamp(); _hasRendered = true;
            refreshed = Refreshed; commands = _commands.ToArray();
        }
        try { refreshed?.Invoke(this, EventArgs.Empty); foreach (var command in commands) command.PublishCanExecuteChanged(); }
        finally
        {
            bool enqueue = false;
            lock (_gate)
            {
                _scheduled = false;
                if (ActiveLocked && _dirty) enqueue = ScheduleIfReadyLocked();
            }
            if (enqueue) EnqueueScheduled();
        }
    }
    private void ReportFailure(Exception exception)
    {
        Observe(ReportFailureAsync(exception));
    }
    private async Task ReportFailureAsync(Exception exception)
    {
        try { await _store.ReportPresentationFailureAsync(exception).ConfigureAwait(false); }
        catch (ObjectDisposedException) when (_store.State.Phase == ShellPhase.Disposed) { }
    }
    internal static void Observe(Task task) => _ = task.ContinueWith(static completed => _ = completed.Exception, CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    public void Dispose()
    {
        ShellCommand[] commands;
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true; _dirty = false; _scheduled = false; _timerArmed = false;
            commands = _commands.ToArray(); _commands.Clear(); Refreshed = null;
        }
        _store.Changed -= StoreChanged; _timer.Dispose();
        foreach (var command in commands) command.Deactivate();
    }
}
public sealed class ShellCommand : ICommand
{
    private readonly ShellUiContext _context;
    private readonly Func<object?, bool> _canExecute;
    private readonly Func<object?, Task> _execute;
    private int _executing;
    private Task? _execution;
    internal ShellCommand(ShellUiContext context, Func<object?, bool> canExecute, Func<object?, Task> execute)
    {
        _context = context ?? throw new ArgumentNullException(nameof(context));
        _canExecute = canExecute ?? throw new ArgumentNullException(nameof(canExecute));
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
    }
    public Task? Execution => Volatile.Read(ref _execution);
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => _context.IsActive && _context.Store.State.Phase == ShellPhase.Running &&
        Volatile.Read(ref _executing) == 0 && _canExecute(parameter);
    public void Execute(object? parameter)
    {
        if (!CanExecute(parameter) || Interlocked.CompareExchange(ref _executing, 1, 0) != 0) return;
        if (!_context.IsActive || _context.Store.State.Phase != ShellPhase.Running) { Interlocked.Exchange(ref _executing, 0); return; }
        var execution = RunAsync(parameter); Volatile.Write(ref _execution, execution); ShellUiContext.Observe(execution);
    }
    private async Task RunAsync(object? parameter)
    {
        try
        {
            try { await _execute(parameter).ConfigureAwait(false); }
            catch (Exception exception)
            {
                try { await _context.Store.ReportPresentationFailureAsync(exception).ConfigureAwait(false); }
                catch (ObjectDisposedException) when (_context.Store.State.Phase == ShellPhase.Disposed) { }
            }
        }
        finally { Interlocked.Exchange(ref _executing, 0); _context.RequestRefresh(); }
    }
    internal void PublishCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    internal void Deactivate() => CanExecuteChanged = null;
}
public abstract class ScreenViewModel : INotifyPropertyChanged
{
    protected ScreenViewModel(ShellUiContext context)
    {
        Context = context ?? throw new ArgumentNullException(nameof(context));
        Context.Refreshed += ContextRefreshed;
    }
    protected ShellUiContext Context { get; }
    protected ShellState Snapshot => Context.State;
    protected ShellCommand Command(Func<object?, bool> canExecute, Func<object?, Task> execute) => Context.Command(canExecute, execute);
    public event PropertyChangedEventHandler? PropertyChanged;
    private void ContextRefreshed(object? sender, EventArgs args) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    public ShellPhase Phase => Snapshot.Phase;
    public EngineFailure? LastError => Snapshot.LastError;
    public string? CommandError => Snapshot.CommandError;
    public string? StoreFailure => Snapshot.StoreFailure;
}
