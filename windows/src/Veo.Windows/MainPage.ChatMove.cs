using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;

namespace Veo_Windows;

public sealed partial class MainPage
{
    async Task MoveChatPickerAsync(ThreadSession session)
    {
        if (session.IsSubmitting || session.Timeline.IsRunning || session.Queue.Count > 0 || session.DispatchWarning is not null)
            throw new InvalidOperationException("Wait for active, queued, or unresolved work before moving this chat.");
        var projects = (await workspace.Threads.ListThreadsAsync(limit: 10000))
            .Where(record => record.WorkspaceKind == "project" && Directory.Exists(record.Cwd)
                && !record.Cwd.Equals(session.Record.Cwd, StringComparison.OrdinalIgnoreCase))
            .Select(record => record.Cwd).Distinct(StringComparer.OrdinalIgnoreCase).Order().ToArray();
        var panel = new StackPanel { Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = projects.Length == 0 ? "Open another project to add a destination."
            : "Future turns will run in the selected folder. The conversation and draft will move with the chat.", TextWrapping = TextWrapping.Wrap });
        var list = new ListView { MaxHeight = 280, SelectionMode = ListViewSelectionMode.Single };
        AutomationProperties.SetName(list, "Destination project");
        foreach (var path in projects)
        {
            var content = new StackPanel { Spacing = 2 };
            content.Children.Add(new TextBlock { Text = Path.GetFileName(Path.TrimEndingDirectorySeparator(path)), FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
            content.Children.Add(new TextBlock { Text = path, TextWrapping = TextWrapping.Wrap, Opacity = .72 });
            list.Items.Add(new ListViewItem { Content = content, Tag = path });
        }
        panel.Children.Add(list);
        var dialog = new ContentDialog { Title = "Move to project", XamlRoot = XamlRoot, Content = panel,
            PrimaryButtonText = "Move chat", CloseButtonText = "Cancel", IsPrimaryButtonEnabled = false,
            DefaultButton = ContentDialogButton.Primary };
        list.SelectionChanged += (_, _) => dialog.IsPrimaryButtonEnabled = list.SelectedItem is ListViewItem;
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || list.SelectedItem is not ListViewItem { Tag: string destination }) return;
        await SaveDraftNowAsync();
        await workspace.MoveChatAsync(session, destination);
        await RefreshCatalogAsync();
        Render();
    }
}
