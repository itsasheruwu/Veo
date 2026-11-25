using Veo.Core;
using Veo_Windows.Controls;

namespace Veo_Windows;

public sealed partial class MainPage
{
    bool tourOpen;

    public async Task ReplayTourAsync()
    {
        await ready.Task;
        if (tourOpen) return;
        workspace.Preferences.WorkspaceTourStep = 0;
        await Run(ShowTourAsync);
    }

    async Task ShowTourAsync()
    {
        if (tourOpen || App.Main is not { } window) return;
        tourOpen = true;
        window.EnterTour();
        string? folder = null;
        try
        {
            while (true)
            {
                var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                var tour = new WorkspaceTour(workspace, ApplyTheme, () => done.TrySetResult());
                window.ShowTourControl(tour);
                await done.Task;
                tour.IsEnabled = false;
                if (!tour.WantsFolder) break;
                folder = await PickProjectFolderAsync();
                if (folder is not null) break;
            }
            workspace.Preferences.WorkspaceTourStep = VeoPreferences.TourCompleted;
            await workspace.SavePreferencesAsync();
        }
        finally
        {
            await window.RevealWorkspaceAsync();
            tourOpen = false;
        }
        if (folder is not null)
        {
            await ready.Task;
            await CreateProjectChatAsync(folder);
        }
    }
}
