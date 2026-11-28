using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using Veo.Platform.Windows.Audio;
using Veo.Platform.Windows.Security;
using Veo.Platform.Windows.Shell;
using Veo.Platform.Windows.Terminal;

if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 26100)) throw new PlatformNotSupportedException("Requires Windows 11 24H2 or later.");
var screen = new TerminalBuffer(8, 3);
screen.Feed("main\u001b[?1049hALT");
Assert(screen.Snapshot().AlternateScreen && screen.CopyText().StartsWith("ALT"), "VT alternate screen has independent content");
screen.Feed("\u001b[?1049l");
Assert(!screen.Snapshot().AlternateScreen && screen.CopyText().StartsWith("main"), "VT restores primary content");
screen.Feed("\u001b[2J\u001b[H\u001b[38;2;1;"); screen.Feed("2;3mX");
Assert(screen.Snapshot().Rows[0][0].Text == "X" && screen.Snapshot().Rows[0][0].Foreground == 0x010203, "split VT true-color sequence");
var reply = ""; screen.ResponseRequested += value => reply = value;
screen.Feed("\u001b[6n"); Assert(reply == "\u001b[1;2R", "VT cursor query responds with actual cell");
screen.Feed("\u001b[H\u001b[0m\ud83d"); screen.Feed("\ude00");
Assert(screen.Snapshot().Rows[0][0].Text == "😀" && screen.Snapshot().Rows[0][1].Width == 0, "split surrogate pair retains wide glyph");
for (var index = 0; index < 10000; index++) screen.Feed("\r\nline");
Assert(screen.CopyText(true).Split(Environment.NewLine).Length <= TerminalBuffer.MaximumScrollback + 3, "terminal scrollback remains bounded");
var history = new TerminalBuffer(4, 2);
history.Feed("\u001b[31mOLD\r\none\r\ntwo");
Assert(history.Snapshot(1).Rows[0][0].Text == "O" && history.Snapshot(1).Rows[0][0].Foreground == 0xc50f1f, "scrollback retains native cell colors");
history.Resize(6, 3);
Assert(history.Snapshot(1).Rows.All(r => r.Length == 6) && history.Snapshot(1).Rows[0][0].Text == "O", "resize preserves visible history and valid cell bounds");
var splitHistory = new TerminalBuffer(18, 4);
splitHistory.Feed("0123456789ABCDEFGHijk\r\nnext");
splitHistory.Resize(9, 6);
Assert(splitHistory.CopyText().StartsWith("012345678" + Environment.NewLine + "9ABCDEFGH" + Environment.NewLine + "ijk"), "splitting a terminal preserves the full long historical line");
splitHistory.Resize(24, 5);
splitHistory.Feed("!");
Assert(splitHistory.CopyText().StartsWith("0123456789ABCDEFGHijk" + Environment.NewLine + "next!"), "widening rejoins soft wraps and preserves the active cursor");
var token = Guid.NewGuid().ToString("N");
var credentials = new CredentialManager("PlatformTests-" + token);
try
{
    Assert(credentials.Read("Disposable", "test") is null, "test credential initially absent");
    credentials.Save("Disposable", "test", "Unicode disposable secret Ω " + token);
    Assert(credentials.Read("Disposable", "test")?.Secret == "Unicode disposable secret Ω " + token, "credential exact readback");
    Assert(new CredentialManager("OtherProfile-" + token).Read("Disposable", "test") is null, "credential profile isolation");
    Assert(CredentialManager.BrowserService(new("https://example.com/account?q=1")) != CredentialManager.BrowserService(new("http://example.com/")), "browser origins retain scheme");
}
finally { credentials.Delete("Disposable", "test"); }
Assert(credentials.Read("Disposable", "test") is null, "test credential removed");
Assert(Path.IsPathFullyQualified(KnownFolders.Downloads), "Downloads resolved through Known Folder API");
Console.WriteLine($"Audio enumeration: {WasapiAudioService.EnumerateDevices().Count} active devices. No microphone capture started.");

var transcript = new StringBuilder();
var outputGate = new object();
var expected = "VEO_CONPTY_" + token;
var session = new ConPtySession();
session.OutputReceived += chunk => { lock (outputGate) transcript.Append(chunk); };
var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
session.Start(shell, Path.GetTempPath(), 80, 24, ["-NoLogo", "-NoProfile"]);
var pid = session.ProcessId!.Value;
int? childPid = null;
try
{
    await session.WriteAsync("[Console]::WriteLine('" + expected + "'); [Console]::WriteLine('SIZE='+[Console]::WindowWidth+'x'+[Console]::WindowHeight)\r");
    await WaitUntil(() => { lock (outputGate) return transcript.ToString().Contains("SIZE=80x24"); }, "initial ConPTY viewport and shell execution");
    session.Resize(101, 31);
    await session.WriteAsync("[Console]::WriteLine('RESIZE='+[Console]::WindowWidth+'x'+[Console]::WindowHeight)\r");
    await WaitUntil(() => { lock (outputGate) return transcript.ToString().Contains("RESIZE=101x31"); }, "ConPTY resize reached shell");
    // Verify a real long-running foreground command can be interrupted through terminal input.
    await session.WriteAsync("Start-Sleep -Seconds 60\r");
    await Task.Delay(350);
    int interruptStart;
    lock (outputGate) interruptStart = transcript.Length;
    await session.WriteAsync("\u0003");
    await WaitUntil(() => { lock (outputGate) return transcript.ToString(interruptStart, transcript.Length - interruptStart).Contains("PS "); }, "terminal Ctrl+C returned a prompt");
    await session.WriteAsync("[Console]::WriteLine('INTERRUPTED_' + '" + token + "')\r");
    await WaitUntil(() => { lock (outputGate) return transcript.ToString().Contains("INTERRUPTED_" + token); }, "terminal Ctrl+C restored shell input");
    await session.WriteAsync("[Console]::WriteLine('CHILD_PID='+ (Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList '-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 60' -WindowStyle Hidden -PassThru).Id)\r");
    await WaitUntil(() => { lock (outputGate) { var match = Regex.Match(transcript.ToString(), @"CHILD_PID=(\d+)"); if (match.Success) childPid = int.Parse(match.Groups[1].Value); return childPid is not null; } }, "owned shell descendant started");
}
catch
{
    lock (outputGate) Console.WriteLine("Captured terminal character count: " + transcript.Length + ". Shell content is not logged.");
    throw;
}
finally { await session.DisposeAsync(); }
Assert(!session.IsRunning, "disposed terminal is inactive");
try { using var staleProcess = Process.GetProcessById(pid); Assert(staleProcess.HasExited, "owned shell exited on dispose"); }
catch (ArgumentException) { Console.WriteLine("PASS owned shell no longer exists"); }
if (childPid is int ownedChild)
{
    try { using var staleProcess = Process.GetProcessById(ownedChild); Assert(staleProcess.HasExited, "owned descendant exited on dispose"); }
    catch (ArgumentException) { Console.WriteLine("PASS owned descendant no longer exists"); }
}
Console.WriteLine("Platform integration checks passed. Native terminal rendering, physical input, audio capture/playback, and packaged activation remain separate acceptance checks.");

static void Assert(bool condition, string label)
{ if (!condition) throw new InvalidOperationException("FAIL " + label); Console.WriteLine("PASS " + label); }
static async Task WaitUntil(Func<bool> condition, string label)
{
    using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    while (!condition()) await Task.Delay(50, timeout.Token);
    Console.WriteLine("PASS " + label);
}
