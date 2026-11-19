using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Veo.Core;
using Veo.Infrastructure.Files;

namespace Veo_Windows.Controls;

internal static class InlineContextPreview
{
    public static async Task ShowAsync(ThreadSession session, string kind, string value, XamlRoot root, int? line)
    {
        if (kind == "terminal")
        {
            await new ContentDialog { Title = "Captured terminal output", CloseButtonText = "Done", XamlRoot = root,
                Content = new TextBox { Text = value, IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 340 } }.ShowAsync();
        }
        else if (kind is "file" or "review")
        {
            var target = new WorkspacePathPolicy(session.Record.Cwd).Resolve(value);
            await new ContentDialog { Title = value, CloseButtonText = "Done", XamlRoot = root,
                Content = new ConversationSourceView(session, new("context", value, target, StartLine: line)) }.ShowAsync();
        }
    }
}
