using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.Windows.AppLifecycle;

namespace MacAmbientJev.WinUI;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        WinRT.ComWrappersSupport.InitializeComWrappers();

        // Subscribe before registering so a launch during UI startup is not lost.
        var appReady = new TaskCompletionSource<App>(TaskCreationOptions.RunContinuationsAsynchronously);
        var current = AppInstance.GetCurrent();
        current.Activated += async (_, _) =>
        {
            var app = await appReady.Task;
            await app.ActivateFromRedirectAsync();
        };
        var instance = AppInstance.FindOrRegisterForKey("MacAmbientJev");
        if (!instance.IsCurrent)
        {
            // Foreground permission is best effort; Windows may deny it when this launcher is not foreground.
            _ = AllowSetForegroundWindow(instance.ProcessId);
            var activation = current.GetActivatedEventArgs();
            // Redirect on an MTA worker, not the STA waiting for its completion.
            // GetAwaiter().GetResult() propagates failures without launching another app.
            Task.Run(async () => await instance.RedirectActivationToAsync(activation)).GetAwaiter().GetResult();
            return;
        }

        Application.Start(_ =>
        {
            var dispatcher = DispatcherQueue.GetForCurrentThread() ??
                throw new InvalidOperationException("The UI dispatcher is unavailable.");
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(dispatcher));
            appReady.SetResult(new App());
        });
        GC.KeepAlive(current);
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AllowSetForegroundWindow(uint processId);
}
