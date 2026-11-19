using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Channels;
using Microsoft.Win32.SafeHandles;

namespace Veo.Platform.Windows.Terminal;

/// <summary>Owns one ConPTY shell and its descendants. Output callbacks run off the UI thread.</summary>
public sealed class ConPtySession : IAsyncDisposable
{
    private readonly object gate = new();
    private readonly Channel<WriteRequest> writes = Channel.CreateBounded<WriteRequest>(new BoundedChannelOptions(256) { SingleReader = true, FullMode = BoundedChannelFullMode.Wait });
    private readonly TaskCompletionSource<int> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private nint pseudoConsole, process, job;
    private FileStream? input, output;
    private Task? readTask, writeTask, waitTask;
    private bool started, disposed;
    public event Action<string>? OutputReceived;
    public event Action<Exception>? Faulted;
    public int? ProcessId { get; private set; }
    public bool IsRunning => started && !completion.Task.IsCompleted && !disposed;
    public Task<int> Completion => completion.Task;

    public void Start(string executable, string cwd, int columns, int rows, IReadOnlyList<string>? arguments = null)
    {
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (started) throw new InvalidOperationException("A terminal session can only be started once.");
            if (!Path.IsPathFullyQualified(executable) || !File.Exists(executable)) throw new FileNotFoundException("Select an existing shell executable.", executable);
            if (!Directory.Exists(cwd)) throw new DirectoryNotFoundException("The terminal working directory is unavailable.");
            var size = ValidateSize(columns, rows);
            SafeFileHandle? consoleInput = null, inputWriter = null, outputReader = null, consoleOutput = null;
            nint attributeList = 0;
            ConPtyNative.ProcessInformation processInfo = default;
            try
            {
                ConPtyNative.Check(ConPtyNative.CreatePipe(out consoleInput, out inputWriter, 0, 0), "Create terminal input pipe");
                ConPtyNative.Check(ConPtyNative.CreatePipe(out outputReader, out consoleOutput, 0, 0), "Create terminal output pipe");
                Marshal.ThrowExceptionForHR(ConPtyNative.CreatePseudoConsole(size, consoleInput, consoleOutput, 0, out pseudoConsole));
                nuint attributeBytes = 0;
                ConPtyNative.InitializeProcThreadAttributeList(0, 1, 0, ref attributeBytes);
                attributeList = Marshal.AllocHGlobal(checked((int)attributeBytes));
                ConPtyNative.Check(ConPtyNative.InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeBytes), "Initialize terminal process attributes");
                ConPtyNative.Check(ConPtyNative.UpdateProcThreadAttribute(attributeList, 0, ConPtyNative.PseudoConsoleAttribute, pseudoConsole, (nuint)nint.Size, 0, 0), "Attach terminal pseudoconsole");
                job = ConPtyNative.CreateJobObjectW(0, null);
                ConPtyNative.Check(job != 0, "Create owned terminal process job");
                var limits = new ConPtyNative.ExtendedLimitInformation { BasicLimitInformation = new() { LimitFlags = ConPtyNative.KillOnJobClose } };
                ConPtyNative.Check(ConPtyNative.SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ConPtyNative.ExtendedLimitInformation>()), "Set owned terminal process limits");
                // Explicitly request fresh console standard handles. A redirected parent
                // (for example the integration harness) must not leak its pipes into the shell.
                var startup = new ConPtyNative.StartupInfoEx { StartupInfo = new() { Size = Marshal.SizeOf<ConPtyNative.StartupInfoEx>(), Flags = 0x100 }, AttributeList = attributeList };
                var command = new StringBuilder(QuoteArgument(executable));
                foreach (var arg in arguments ?? []) command.Append(' ').Append(QuoteArgument(arg));
                ConPtyNative.Check(ConPtyNative.CreateProcessW(executable, command, 0, 0, false, ConPtyNative.ExtendedStartupInfoPresent | ConPtyNative.CreateSuspended, 0, Path.GetFullPath(cwd), ref startup, out processInfo), "Start terminal shell");
                process = processInfo.Process;
                ConPtyNative.Check(ConPtyNative.AssignProcessToJobObject(job, process), "Assign shell to owned terminal job");
                input = new FileStream(inputWriter, FileAccess.Write, 4096, false); inputWriter = null;
                output = new FileStream(outputReader, FileAccess.Read, 4096, false); outputReader = null;
                started = true;
                ProcessId = checked((int)processInfo.ProcessId);
                readTask = Task.Run(ReadOutput);
                writeTask = Task.Run(WriteInput);
                waitTask = Task.Run(WaitForExit);
                if (ConPtyNative.ResumeThread(processInfo.Thread) == uint.MaxValue) throw new Win32Exception(Marshal.GetLastWin32Error(), "Resume terminal shell");
            }
            catch
            {
                if (process != 0) ConPtyNative.TerminateProcess(process, 1);
                if (job != 0) { ConPtyNative.CloseHandle(job); job = 0; }
                if (pseudoConsole != 0) { ConPtyNative.ClosePseudoConsole(pseudoConsole); pseudoConsole = 0; }
                input?.Dispose(); output?.Dispose();
                if (process != 0) { ConPtyNative.CloseHandle(process); process = 0; }
                writes.Writer.TryComplete();
                completion.TrySetResult(1);
                disposed = true;
                throw;
            }
            finally
            {
                if (processInfo.Thread != 0) ConPtyNative.CloseHandle(processInfo.Thread);
                if (attributeList != 0) { ConPtyNative.DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                consoleInput?.Dispose(); consoleOutput?.Dispose(); inputWriter?.Dispose(); outputReader?.Dispose();
            }
        }
    }

    public async Task WriteAsync(string text, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (!IsRunning) throw new InvalidOperationException("The terminal is not running.");
        var request = new WriteRequest(Encoding.UTF8.GetBytes(text));
        await writes.Writer.WriteAsync(request, cancellationToken).ConfigureAwait(false);
        await request.Completion.Task.WaitAsync(cancellationToken).ConfigureAwait(false);
    }

    public void Resize(int columns, int rows)
    {
        var size = ValidateSize(columns, rows);
        lock (gate)
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (pseudoConsole != 0) Marshal.ThrowExceptionForHR(ConPtyNative.ResizePseudoConsole(pseudoConsole, size));
        }
    }

    private void ReadOutput()
    {
        try
        {
            using var reader = new StreamReader(output!, new UTF8Encoding(false, false), false, 4096, leaveOpen: true);
            var buffer = new char[4096];
            int length;
            while ((length = reader.Read(buffer, 0, buffer.Length)) != 0) OutputReceived?.Invoke(new string(buffer, 0, length));
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException) { if (!disposed && !completion.Task.IsCompleted) Faulted?.Invoke(ex); }
    }

    private async Task WriteInput()
    {
        Exception? failure = null;
        try
        {
            await foreach (var request in writes.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                try { input!.Write(request.Bytes); input.Flush(); request.Completion.TrySetResult(); }
                catch (Exception ex) { request.Completion.TrySetException(ex); throw; }
            }
        }
        catch (Exception ex) { failure = ex; if (!disposed) Faulted?.Invoke(ex); }
        finally
        {
            writes.Writer.TryComplete(failure);
            while (writes.Reader.TryRead(out var request)) request.Completion.TrySetException(failure ?? new IOException("The terminal input closed."));
        }
    }

    private void WaitForExit()
    {
        var handle = process;
        ConPtyNative.WaitForSingleObject(handle, uint.MaxValue);
        ConPtyNative.GetExitCodeProcess(handle, out var code);
        completion.TrySetResult(unchecked((int)code));
        writes.Writer.TryComplete();
    }

    public async ValueTask DisposeAsync()
    {
        nint consoleToClose, jobToClose;
        lock (gate)
        {
            if (disposed) return;
            disposed = true;
            writes.Writer.TryComplete();
            consoleToClose = pseudoConsole; pseudoConsole = 0;
            jobToClose = job; job = 0;
        }
        // Keep the independent output reader draining the final ConPTY frame during close.
        await Task.Run(() =>
        {
            if (jobToClose != 0) { ConPtyNative.TerminateJobObject(jobToClose, 1); ConPtyNative.CloseHandle(jobToClose); }
            if (consoleToClose != 0) ConPtyNative.ClosePseudoConsole(consoleToClose);
        }).ConfigureAwait(false);
        input?.Dispose();
        if (waitTask is not null) await waitTask.ConfigureAwait(false);
        if (readTask is not null) await readTask.ConfigureAwait(false);
        output?.Dispose();
        if (writeTask is not null) await writeTask.ConfigureAwait(false);
        if (process != 0) { ConPtyNative.CloseHandle(process); process = 0; }
        completion.TrySetResult(0);
    }

    private static ConPtyNative.Coord ValidateSize(int columns, int rows)
    {
        if (columns is < 1 or > short.MaxValue || rows is < 1 or > short.MaxValue) throw new ArgumentOutOfRangeException(nameof(columns), "Terminal dimensions must be 1–32767 cells.");
        return new((short)columns, (short)rows);
    }

    private static string QuoteArgument(string value)
    {
        if (value.Contains('\0')) throw new ArgumentException("An executable argument contains a null character.");
        var result = new StringBuilder("\"");
        var slashes = 0;
        foreach (var c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1).Append('"');
            else result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }

    private sealed record WriteRequest(byte[] Bytes)
    { internal TaskCompletionSource Completion { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously); }
}
