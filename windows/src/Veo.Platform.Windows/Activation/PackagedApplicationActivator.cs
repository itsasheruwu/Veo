using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;

namespace Veo.Platform.Windows.Activation;

public static class PackagedApplicationActivator
{
    public static void ValidateAumid(string appUserModelId)
    {
        if (!Regex.IsMatch(appUserModelId, @"^[A-Za-z0-9.-]+_[A-Za-z0-9]+![A-Za-z0-9._-]+$")) throw new ArgumentException("A stable package family and application identity are required.", nameof(appUserModelId));
    }

    public static uint ActivateContinuation(string appUserModelId, string jobId)
    {
        ValidateAumid(appUserModelId);
        if (!Guid.TryParse(jobId, out _)) throw new ArgumentException("A continuation activation needs its stored GUID identity.", nameof(jobId));
        var type = Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"), throwOnError: true)!;
        var manager = (IApplicationActivationManager)Activator.CreateInstance(type)!;
        try
        {
            // AO_NOERRORUI suppresses an unattended error dialog; the app handles quiet mode.
            Marshal.ThrowExceptionForHR(manager.ActivateApplication(appUserModelId, "--continuation-job " + QuoteArgument(jobId) + " --quiet", 2, out var processId));
            return processId;
        }
        finally { Marshal.FinalReleaseComObject(manager); }
    }

    public static string QuoteArgument(string argument)
    {
        if (argument.Contains('\0')) throw new ArgumentException("An argument contains a null character.", nameof(argument));
        var quoted = new StringBuilder("\"");
        var slashCount = 0;
        foreach (var character in argument)
        {
            if (character == '\\') { slashCount++; continue; }
            if (character == '"') quoted.Append('\\', slashCount * 2 + 1).Append('"');
            else quoted.Append('\\', slashCount).Append(character);
            slashCount = 0;
        }
        return quoted.Append('\\', slashCount * 2).Append('"').ToString();
    }

    [ComImport, Guid("2E941141-7F97-4756-BA1D-9DECDE894A3D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager
    {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, uint options, out uint processId);
        [PreserveSig] int ActivateForFile([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, nint itemArray, [MarshalAs(UnmanagedType.LPWStr)] string verb, out uint processId);
        [PreserveSig] int ActivateForProtocol([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, nint itemArray, out uint processId);
    }
}
