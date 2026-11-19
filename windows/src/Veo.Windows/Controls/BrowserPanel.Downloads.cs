using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using Veo.Platform.Windows.Browser;

namespace Veo_Windows.Controls;
public sealed partial class BrowserPanel
{
    readonly List<Download> downloads = [];
    readonly StackPanel downloadRows = new()
    {
        Spacing = 8
    };
    readonly StackPanel downloadsPanel = new()
    {
        Visibility = Visibility.Collapsed,
        MaxHeight = 240
    };
    sealed class Download(CoreWebView2DownloadOperation operation, string destination)
    {
        public readonly CoreWebView2DownloadOperation Operation = operation;
        public readonly string Destination = destination;
        public readonly TextBlock Label = new()
        {
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 580
        };
        public readonly ProgressBar Progress = new()
        {
            Minimum = 0,
            Maximum = 100,
            IsIndeterminate = true
        };
        public readonly Button Cancel = new()
        {
            Content = "Cancel"
        }, Open = new()
        {
            Content = "Open",
            IsEnabled = false
        }, Reveal = new()
        {
            Content = "Reveal",
            IsEnabled = false
        };
        public VerifiedBrowserDownload? Verified;
        public bool Verifying;
    }

    void BuildDownloads(StackPanel parent)
    {
        downloadsPanel.Children.Add(new ScrollViewer { Content = downloadRows, MaxHeight = 220 });
        var clear = new Button
        {
            Content = "Clear finished downloads"
        };
        clear.Click += (_, _) =>
        {
            foreach (var download in downloads.Where(d => d.Operation.State != CoreWebView2DownloadState.InProgress).ToArray())
            {
                var index = downloads.IndexOf(download);
                downloads.RemoveAt(index);
                downloadRows.Children.RemoveAt(downloadRows.Children.Count - 1 - index);
            }
        };
        downloadsPanel.Children.Add(clear);
        parent.Children.Add(downloadsPanel);
    }

    void StartDownload(Tab source, CoreWebView2DownloadStartingEventArgs args)
    {
        if (disposed || source.Closed || source.PreviewRoot is not null || downloads.Count >= 64)
        {
            args.Cancel = true;
            progress.Text = "This download is not permitted, or the 64-item download list is full.";
            return;
        }

        try
        {
            var destination = BrowserDownloadDestination.Reserve(Path.GetFileName(args.ResultFilePath));
            args.ResultFilePath = destination;
            args.Handled = true;
            var download = new Download(args.DownloadOperation, destination);
            downloads.Add(download);
            var row = new StackPanel
            {
                Spacing = 3
            };
            row.Children.Add(download.Label);
            row.Children.Add(download.Progress);
            var actions = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Spacing = 8
            };
            actions.Children.Add(download.Cancel);
            actions.Children.Add(download.Open);
            actions.Children.Add(download.Reveal);
            row.Children.Add(actions);
            downloadRows.Children.Insert(0, row);
            downloadsPanel.Visibility = Visibility.Visible;
            download.Cancel.Click += (_, _) =>
            {
                download.Operation.Cancel();
                download.Cancel.IsEnabled = false;
            };
            download.Open.Click += (_, _) => Guard(async () =>
            {
                if (download.Verified is { } verified)
                {
                    var readback = await BrowserDownloadDestination.VerifyAsync(verified.Path);
                    if (readback != verified)
                        throw new IOException("The downloaded file changed since verification.");
                    await Windows.System.Launcher.LaunchFileAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(verified.Path));
                }
            });
            download.Reveal.Click += (_, _) => Guard(async () =>
            {
                if (download.Verified is { } verified)
                {
                    var options = new Windows.System.FolderLauncherOptions();
                    options.ItemsToSelect.Add(await Windows.Storage.StorageFile.GetFileFromPathAsync(verified.Path));
                    await Windows.System.Launcher.LaunchFolderPathAsync(Path.GetDirectoryName(verified.Path)!, options);
                }
            });
            download.Operation.BytesReceivedChanged += (_, _) => UpdateDownload(download);
            download.Operation.StateChanged += (_, _) => UpdateDownload(download);
            UpdateDownload(download);
        }
        catch (Exception error)
        {
            args.Cancel = true;
            progress.Text = "Download could not start: " + error.Message;
        }
    }

    void UpdateDownload(Download download)
    {
        if (disposed)
            return;
        var op = download.Operation;
        download.Label.Text = Path.GetFileName(download.Destination) + $" — {op.BytesReceived:N0}" + (op.TotalBytesToReceive > 0 ? $" / {op.TotalBytesToReceive:N0} bytes" : " bytes");
        download.Progress.IsIndeterminate = op.TotalBytesToReceive <= 0;
        if (op.TotalBytesToReceive is> 0)
            download.Progress.Value = Math.Clamp(100d * op.BytesReceived / op.TotalBytesToReceive, 0, 100);
        if (op.State == CoreWebView2DownloadState.Interrupted)
        {
            download.Cancel.IsEnabled = false;
            download.Label.Text += " — Interrupted: " + op.InterruptReason;
        }

        if (op.State != CoreWebView2DownloadState.Completed || download.Verifying)
            return;
        download.Verifying = true;
        download.Cancel.IsEnabled = false;
        Guard(async () =>
        {
            download.Verified = await BrowserDownloadDestination.VerifyAsync(download.Destination);
            if (disposed)
                return;
            download.Label.Text = $"Saved {download.Verified.Path} ({download.Verified.Length:N0} bytes; read verified)";
            download.Progress.IsIndeterminate = false;
            download.Progress.Value = 100;
            download.Open.IsEnabled = download.Reveal.IsEnabled = true;
        });
    }

    void CancelDownloads()
    {
        foreach (var download in downloads)
            if (download.Operation.State == CoreWebView2DownloadState.InProgress)
                download.Operation.Cancel();
    }
}
