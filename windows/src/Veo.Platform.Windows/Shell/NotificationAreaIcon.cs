using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Veo.Platform.Windows.Shell;

public enum TrayCommand { Show, NewChat, Settings, Quit }

/// <summary>One process-owned notification-area icon; native menu, no second UI or runtime owner.</summary>
public sealed class NotificationAreaIcon : IDisposable
{
    const uint Callback = 0x8000 + 0x254;
    readonly nint window;
    readonly SubclassProc callback;
    readonly uint taskbarCreated;
    readonly nint icon;
    readonly bool ownsIcon;
    bool added, disposed;
    public event Action<TrayCommand>? Invoked;
    public NotificationAreaIcon(nint window, string iconFile)
    {
        this.window = window;
        callback = Procedure; taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
        icon = LoadImageW(0, iconFile, 1, 16, 16, 0x10); ownsIcon = icon != 0;
        if (icon == 0) icon = LoadIconW(0, (nint)32512);
        if (!SetWindowSubclass(window, callback, 0x56454F, 0)) { if (ownsIcon) DestroyIcon(icon); throw new Win32Exception(Marshal.GetLastWin32Error(), "Attach Veo tray commands"); }
        try { Add(); }
        catch { RemoveWindowSubclass(window, callback, 0x56454F); if (ownsIcon) DestroyIcon(icon); throw; }
    }
    void Add()
    {
        var data = Data();
        if (!Shell_NotifyIconW(0, ref data)) throw new Win32Exception(Marshal.GetLastWin32Error(), "Show Veo notification-area icon");
        added = true; data.Version = 4; Shell_NotifyIconW(4, ref data);
    }
    NotifyIconData Data() => new()
    {
        Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = window, Id = 1, Flags = 1 | 2 | 4,
        CallbackMessage = Callback, Icon = icon, Tip = "Veo", Info = "", InfoTitle = ""
    };
    nint Procedure(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference)
    {
        if (message == taskbarCreated && !disposed) { added = false; try { Add(); } catch (Win32Exception) { } }
        if (message == Callback && !disposed)
        {
            var action = (uint)lParam & 0xffff;
            if (action is 0x400 or 0x401 or 0x203) Invoked?.Invoke(TrayCommand.Show);
            else if (action is 0x7b or 0x205) ShowMenu();
            return 0;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }
    void ShowMenu()
    {
        var menu = CreatePopupMenu(); if (menu == 0) return;
        try
        {
            AppendMenuW(menu, 0, 1001, "Show Veo"); AppendMenuW(menu, 0, 1002, "New chat");
            AppendMenuW(menu, 0, 1003, "Settings"); AppendMenuW(menu, 0x800, 0, null); AppendMenuW(menu, 0, 1004, "Quit Veo");
            GetCursorPos(out var point); SetForegroundWindow(window);
            var selected = TrackPopupMenuEx(menu, 0x100 | 0x2, point.X, point.Y, window, 0);
            if (selected is >= 1001 and <= 1004) Invoked?.Invoke((TrayCommand)(selected - 1001));
            PostMessageW(window, 0, 0, 0);
        }
        finally { DestroyMenu(menu); }
    }
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        if (added) { var data = Data(); Shell_NotifyIconW(2, ref data); added = false; }
        RemoveWindowSubclass(window, callback, 0x56454F); if (ownsIcon) DestroyIcon(icon);
    }
    delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint reference);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct NotifyIconData
    {
        internal uint Size; internal nint Window; internal uint Id, Flags, CallbackMessage; internal nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Tip;
        internal uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Info;
        internal uint Version;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string InfoTitle;
        internal uint InfoFlags; internal Guid Guid; internal nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] struct Point { internal int X, Y; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool Shell_NotifyIconW(uint message, ref NotifyIconData data);
    [DllImport("comctl32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool SetWindowSubclass(nint window, SubclassProc callback, nuint id, nuint reference);
    [DllImport("comctl32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool RemoveWindowSubclass(nint window, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessageW(string message);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint LoadImageW(nint instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] static extern nint LoadIconW(nint instance, nint name);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll")] static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool AppendMenuW(nint menu, uint flags, nuint id, string? text);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] static extern uint TrackPopupMenuEx(nint menu, uint flags, int x, int y, nint window, nint parameters);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool PostMessageW(nint window, uint message, nuint wParam, nint lParam);
}
