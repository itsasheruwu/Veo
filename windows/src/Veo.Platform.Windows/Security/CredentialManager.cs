using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Veo.Platform.Windows.Security;

public sealed record StoredCredential(string Account, string Secret);

/// <summary>Current-user Windows Credential Manager storage, separated by Veo profile and service.</summary>
public sealed class CredentialManager
{
    private readonly string prefix;
    public CredentialManager(string profile = "Development")
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(profile);
        prefix = "Veo/" + Uri.EscapeDataString(profile) + "/";
    }

    public void Save(string service, string account, string secret)
    {
        ArgumentNullException.ThrowIfNull(secret);
        var bytes = Encoding.UTF8.GetBytes(secret);
        if (bytes.Length > 2560) { CryptographicOperations.ZeroMemory(bytes); throw new ArgumentOutOfRangeException(nameof(secret), "Credential exceeds the Windows generic-credential limit."); }
        var memory = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, memory, bytes.Length);
            var credential = new NativeCredential { Type = 1, TargetName = Target(service, account), UserName = account, CredentialBlob = memory, CredentialBlobSize = (uint)bytes.Length, Persist = 2 };
            if (!CredWriteW(ref credential, 0)) throw Error("Save Veo credential");
        }
        finally
        {
            unsafe { CryptographicOperations.ZeroMemory(new Span<byte>((void*)memory, bytes.Length)); }
            Marshal.FreeHGlobal(memory);
            CryptographicOperations.ZeroMemory(bytes);
        }
    }

    public StoredCredential? Read(string service, string account)
    {
        if (!CredReadW(Target(service, account), 1, 0, out var pointer))
        {
            if (Marshal.GetLastWin32Error() == 1168) return null;
            throw Error("Read Veo credential");
        }
        try
        {
            var credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            var bytes = new byte[credential.CredentialBlobSize];
            try
            {
                Marshal.Copy(credential.CredentialBlob, bytes, 0, bytes.Length);
                return new(credential.UserName ?? account, Encoding.UTF8.GetString(bytes));
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        finally { CredFree(pointer); }
    }

    public bool Delete(string service, string account)
    {
        if (CredDeleteW(Target(service, account), 1, 0)) return true;
        if (Marshal.GetLastWin32Error() == 1168) return false;
        throw Error("Remove Veo credential");
    }

    public static string BrowserService(Uri origin)
    {
        if (!origin.IsAbsoluteUri || origin.Scheme is not ("https" or "http") || !string.IsNullOrEmpty(origin.UserInfo)) throw new ArgumentException("A website credential needs an HTTP or HTTPS origin.", nameof(origin));
        return "Browser/" + origin.GetLeftPart(UriPartial.Authority).ToLowerInvariant();
    }

    private string Target(string service, string account)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(service);
        ArgumentException.ThrowIfNullOrWhiteSpace(account);
        return prefix + Uri.EscapeDataString(service) + "/" + Uri.EscapeDataString(account);
    }

    private static Win32Exception Error(string operation) => new(Marshal.GetLastWin32Error(), operation);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        internal uint Flags, Type;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? TargetName;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? Comment;
        internal System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        internal uint CredentialBlobSize;
        internal nint CredentialBlob;
        internal uint Persist, AttributeCount;
        internal nint Attributes;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? TargetAlias;
        [MarshalAs(UnmanagedType.LPWStr)] internal string? UserName;
    }
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWriteW(ref NativeCredential credential, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredReadW(string target, uint type, uint flags, out nint credential);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] private static extern void CredFree(nint buffer);
}
