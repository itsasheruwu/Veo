using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Velopack;

namespace Veo_Windows;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        VelopackApp.Build().SetArgs(args).SetAutoApplyOnStartup(false).Run();
        WinRT.ComWrappersSupport.InitializeComWrappers();
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread()));
            new App();
        });
    }
}
