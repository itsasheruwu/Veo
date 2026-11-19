using System.Runtime.InteropServices;

namespace Veo.Platform.Windows.Shell;

public static class KnownFolders
{
    public static string Downloads => Resolve(new Guid("374DE290-123F-4565-9164-39C4925E467B"));

    private static string Resolve(Guid id)
    {
        Marshal.ThrowExceptionForHR(SHGetKnownFolderPath(ref id, 0, 0, out var path));
        try { return Marshal.PtrToStringUni(path) ?? throw new IOException("Windows did not return the known-folder path."); }
        finally { Marshal.FreeCoTaskMem(path); }
    }

    [DllImport("shell32.dll")] private static extern int SHGetKnownFolderPath(ref Guid folderId, uint flags, nint token, out nint path);
}
