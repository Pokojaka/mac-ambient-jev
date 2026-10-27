using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using MacAmbientJev.Presentation;
using MacAmbientJev.Protocol;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace MacAmbientJev.WinUI;

public sealed partial class SavedSessionsWindow : Window
{
    private readonly SessionsViewModel _sessions;

    public SavedSessionsWindow(Window owner, SessionsViewModel sessions)
    {
        ArgumentNullException.ThrowIfNull(owner);
        ArgumentNullException.ThrowIfNull(sessions);
        InitializeComponent();
        _sessions = sessions;
        Root.DataContext = sessions;
        ReloadButton.CommandParameter = ShellPageMove.Reload;
        PreviousButton.CommandParameter = ShellPageMove.Previous;
        NextButton.CommandParameter = ShellPageMove.Next;

        if (RuntimeInformation.ProcessArchitecture is not (Architecture.X64 or Architecture.Arm64))
            throw new PlatformNotSupportedException("Saved sessions windows require x64 or ARM64.");

        var ownerHandle = WinRT.Interop.WindowNative.GetWindowHandle(owner);
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if (ownerHandle == 0 || windowHandle == 0)
            throw new InvalidOperationException("The saved sessions window or its owner has no HWND.");

        Marshal.SetLastPInvokeError(0);
        var previousOwner = SetWindowLongPtrW(windowHandle, -8, ownerHandle);
        var lastError = Marshal.GetLastPInvokeError();
        if (previousOwner == 0 && lastError != 0) throw new Win32Exception(lastError);

        var appWindow = AppWindow.GetFromWindowId(Microsoft.UI.Win32Interop.GetWindowIdFromWindow(windowHandle))
            ?? throw new InvalidOperationException("The saved sessions window has no AppWindow.");
        if (appWindow.Presenter is not OverlappedPresenter presenter)
            throw new InvalidOperationException("The saved sessions window requires an OverlappedPresenter.");
        presenter.IsResizable = true;
        appWindow.Resize(new Windows.Graphics.SizeInt32(1000, 650));
    }

    private void OnSessionSelectionChanged(object sender, SelectionChangedEventArgs args)
    {
        if (SessionList.SelectedItem is not EngineSessionSummary summary) return;
        if (summary.FolderID == _sessions.SelectedFolderID) return;
        if (_sessions.Select.CanExecute(summary)) _sessions.Select.Execute(summary);
    }

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern nint SetWindowLongPtrW(nint hWnd, int nIndex, nint dwNewLong);
}

internal sealed class ExplorerFolderRevealer : IFolderRevealer
{
    public async Task RevealAsync(string path)
    {
        ArgumentException.ThrowIfNullOrEmpty(path);
        if (!Path.IsPathFullyQualified(path)) throw new ArgumentException("録音フォルダーのパスは絶対パスである必要があります。", nameof(path));
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("録音フォルダが見つかりません: " + path);
        if (!await Windows.System.Launcher.LaunchFolderPathAsync(path))
            throw new InvalidOperationException("録音フォルダーをエクスプローラーで開けませんでした: " + path);
    }
}
