using System.Globalization;
using System.Text;

namespace Veo.Platform.Windows.Terminal;

public readonly record struct TerminalCell(string Text, uint? Foreground = null, uint? Background = null, bool Bold = false, bool Italic = false, bool Underline = false, bool Inverse = false, int Width = 1);
public sealed record TerminalSnapshot(TerminalCell[][] Rows, int CursorColumn, int CursorRow, bool CursorVisible, bool AlternateScreen, bool BracketedPaste, bool ApplicationCursorKeys, int ScrollbackCount, long TotalScrolledLines);

/// <summary>
/// Bounded native-terminal screen model. Handles the common ECMA-48/xterm screen,
/// cursor, color and alternate-screen operations. Advanced Unicode/IME, sixel,
/// terminal mouse reporting and complete VT conformance remain separate work.
/// </summary>
public sealed class TerminalBuffer
{
    private readonly object gate = new();
    private TerminalCell[][] screen;
    private TerminalCell[][]? primaryScreen;
    private readonly Queue<TerminalCell[]> scrollback = new();
    private long totalScrolledLines;
    private readonly StringBuilder sequence = new();
    private ParseState state;
    private TerminalCell style = Blank;
    private int column, row, savedColumn, savedRow, primaryColumn, primaryRow, scrollTop, scrollBottom;
    private bool wrapPending;
    private char? pendingHighSurrogate;
    private bool cursorVisible = true, bracketedPaste, applicationCursorKeys;
    private readonly List<string> replies = [];
    public const int MaximumScrollback = 3000;
    private static readonly TerminalCell Blank = new(" ");
    public event Action<string>? ResponseRequested;
    public int Columns { get; private set; }
    public int Rows { get; private set; }

    public TerminalBuffer(int columns = 80, int rows = 24)
    {
        ValidateSize(columns, rows);
        Columns = columns; Rows = rows;
        screen = NewScreen(columns, rows); scrollBottom = rows - 1;
    }

    public void Feed(string text)
    {
        string[] responses;
        lock (gate)
        {
            foreach (var c in text)
            {
                if (state != ParseState.Ground) { ParseEscape(c); continue; }
                if (c == '\u001b') { state = ParseState.Escape; continue; }
                if (c < ' ' || c == '\u007f') { Control(c); continue; }
                if (pendingHighSurrogate is char high)
                {
                    pendingHighSurrogate = null;
                    if (char.IsLowSurrogate(c)) { Put(new Rune(high, c)); continue; }
                    Put(Rune.ReplacementChar);
                }
                if (char.IsHighSurrogate(c)) pendingHighSurrogate = c;
                else Put(char.IsLowSurrogate(c) ? Rune.ReplacementChar : new Rune(c));
            }
            responses = replies.ToArray(); replies.Clear();
        }
        foreach (var response in responses) ResponseRequested?.Invoke(response);
    }

    public TerminalSnapshot Snapshot(int scrollbackOffset = 0)
    {
        lock (gate)
        {
            var offset = primaryScreen is null ? Math.Clamp(scrollbackOffset, 0, scrollback.Count) : 0;
            var visible = offset == 0 ? screen.AsEnumerable() : scrollback.Concat(screen).Skip(scrollback.Count - offset).Take(Rows);
            // Old history can have a different column count after resize.
            var cells = visible.Select(line => { var resized = NewLineCells(Columns, Blank); Array.Copy(line, resized, Math.Min(line.Length, Columns)); return resized; }).ToArray();
            return new(cells, column, row, cursorVisible && offset == 0, primaryScreen is not null, bracketedPaste, applicationCursorKeys, scrollback.Count, totalScrolledLines);
        }
    }

    public string CopyText(bool includeScrollback = false)
    {
        lock (gate)
        {
            var lines = screen.Select(LineText);
            return string.Join(Environment.NewLine, includeScrollback ? scrollback.Select(LineText).Concat(lines) : lines);
        }
    }

    public void Resize(int columns, int rows)
    {
        ValidateSize(columns, rows);
        lock (gate)
        {
            screen = ResizeScreen(screen, columns, rows);
            if (primaryScreen is not null) primaryScreen = ResizeScreen(primaryScreen, columns, rows);
            Columns = columns; Rows = rows;
            column = Math.Clamp(column, 0, columns - 1); row = Math.Clamp(row, 0, rows - 1);
            scrollTop = 0; scrollBottom = rows - 1; wrapPending = false;
        }
    }

    private void ParseEscape(char c)
    {
        switch (state)
        {
            case ParseState.Escape:
                sequence.Clear();
                state = c switch { '[' => ParseState.Csi, ']' => ParseState.Osc, '(' or ')' or '*' or '+' => ParseState.Charset, _ => ParseState.Ground };
                switch (c)
                {
                    case '7': savedColumn = column; savedRow = row; break;
                    case '8': Move(savedColumn, savedRow); break;
                    case 'D': NewLine(); break;
                    case 'E': column = 0; NewLine(); break;
                    case 'M': if (row == scrollTop) ScrollDown(1); else row = Math.Max(0, row - 1); break;
                    case 'c': Reset(); break;
                }
                break;
            case ParseState.Csi:
                if (c is >= '@' and <= '~') { Csi(c, sequence.ToString()); sequence.Clear(); state = ParseState.Ground; }
                else if (c == '\u001b') { sequence.Clear(); state = ParseState.Escape; }
                else if (sequence.Length < 1024) sequence.Append(c);
                else { sequence.Clear(); state = ParseState.Ground; }
                break;
            case ParseState.Osc:
                // Titles/hyperlinks are intentionally not trusted host commands.
                if (c == '\a') state = ParseState.Ground;
                else if (c == '\u001b') state = ParseState.OscEscape;
                break;
            case ParseState.OscEscape: state = c == '\\' ? ParseState.Ground : ParseState.Osc; break;
            case ParseState.Charset: state = ParseState.Ground; break;
        }
    }

    private void Csi(char command, string raw)
    {
        var privateMode = raw.StartsWith('?');
        var text = raw.TrimStart('?', '>', '!');
        var values = text.Split(';').Select(x => int.TryParse(x, out var number) ? Math.Clamp(number, 0, 1_000_000) : 0).ToArray();
        int Value(int index = 0, int fallback = 1) => index < values.Length && values[index] != 0 ? values[index] : fallback;
        var count = Math.Min(Value(), Math.Max(Columns, Rows));
        switch (command)
        {
            case 'A': Move(column, row - count); break;
            case 'B' or 'e': Move(column, row + count); break;
            case 'C' or 'a': Move(column + count, row); break;
            case 'D': Move(column - count, row); break;
            case 'E': Move(0, row + count); break;
            case 'F': Move(0, row - count); break;
            case 'G' or '`': Move(Value() - 1, row); break;
            case 'd': Move(column, Value() - 1); break;
            case 'H' or 'f': Move(Value(1) - 1, Value() - 1); break;
            case 'J': EraseDisplay(Value(0, 0)); break;
            case 'K': EraseLine(Value(0, 0)); break;
            case 'm': SetStyle(values); break;
            case 's': savedColumn = column; savedRow = row; break;
            case 'u': Move(savedColumn, savedRow); break;
            case 'r':
                scrollTop = Math.Clamp(Value() - 1, 0, Rows - 1);
                scrollBottom = Math.Clamp(Value(1, Rows) - 1, scrollTop, Rows - 1);
                Move(0, 0); break;
            case 'S': ScrollUp(Math.Min(count, scrollBottom - scrollTop + 1)); break;
            case 'T': ScrollDown(Math.Min(count, scrollBottom - scrollTop + 1)); break;
            case 'L': InsertLines(Math.Min(count, Rows - row)); break;
            case 'M': DeleteLines(Math.Min(count, Rows - row)); break;
            case 'P': DeleteCharacters(Math.Min(count, Columns - column)); break;
            case '@': InsertCharacters(Math.Min(count, Columns - column)); break;
            case 'X': Array.Fill(screen[row], ErasedCell, column, Math.Min(count, Columns - column)); break;
            case 'h' or 'l' when privateMode:
                foreach (var value in values)
                {
                    switch (value)
                    {
                        case 1: applicationCursorKeys = command == 'h'; break;
                        case 25: cursorVisible = command == 'h'; break;
                        case 47 or 1047 or 1049: SetAlternate(command == 'h'); break;
                        case 2004: bracketedPaste = command == 'h'; break;
                    }
                }
                break;
            case 'n' when Value(0, 0) == 6: replies.Add($"\u001b[{row + 1};{column + 1}R"); break;
            case 'n' when Value(0, 0) == 5: replies.Add("\u001b[0n"); break;
            case 'c': replies.Add(raw.StartsWith('>') ? "\u001b[>0;0;0c" : "\u001b[?1;2c"); break;
            case 't' when Value() == 18: replies.Add($"\u001b[8;{Rows};{Columns}t"); break;
        }
    }

    private void Control(char c)
    {
        switch (c)
        {
            case '\r': column = 0; wrapPending = false; break;
            case '\n' or '\v' or '\f': NewLine(); break;
            case '\b': column = Math.Max(0, column - 1); wrapPending = false; break;
            case '\t': column = Math.Min(Columns - 1, (column / 8 + 1) * 8); wrapPending = false; break;
        }
    }

    private void Put(Rune rune)
    {
        if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.NonSpacingMark or UnicodeCategory.EnclosingMark)
        {
            var previous = Math.Max(0, column - 1);
            if (screen[row][previous].Width == 0 && previous > 0) previous--;
            screen[row][previous] = screen[row][previous] with { Text = screen[row][previous].Text + rune.ToString() };
            return;
        }
        var width = RuneWidth(rune);
        if (wrapPending || column + width > Columns) { column = 0; NewLine(); }
        screen[row][column] = style with { Text = rune.ToString(), Width = width };
        if (width == 2 && column + 1 < Columns) screen[row][column + 1] = style with { Text = "", Width = 0 };
        column += width;
        if (column >= Columns) { column = Columns - 1; wrapPending = true; }
    }

    private void NewLine()
    {
        wrapPending = false;
        if (row == scrollBottom) ScrollUp(1); else row = Math.Min(Rows - 1, row + 1);
    }
    private void Move(int x, int y) { column = Math.Clamp(x, 0, Columns - 1); row = Math.Clamp(y, 0, Rows - 1); wrapPending = false; }
    private TerminalCell ErasedCell => style with { Text = " ", Width = 1 };
    private void ScrollUp(int count)
    {
        if (primaryScreen is null && scrollTop == 0)
            for (var y = 0; y < count; y++) { scrollback.Enqueue(screen[y].ToArray()); totalScrolledLines++; while (scrollback.Count > MaximumScrollback) scrollback.Dequeue(); }
        for (var y = scrollTop; y <= scrollBottom - count; y++) screen[y] = screen[y + count];
        for (var y = scrollBottom - count + 1; y <= scrollBottom; y++) screen[y] = NewLineCells(Columns, ErasedCell);
    }
    private void ScrollDown(int count)
    {
        for (var y = scrollBottom; y >= scrollTop + count; y--) screen[y] = screen[y - count];
        for (var y = scrollTop; y < scrollTop + count; y++) screen[y] = NewLineCells(Columns, ErasedCell);
    }
    private void InsertLines(int count)
    {
        if (row < scrollTop || row > scrollBottom) return;
        count = Math.Min(count, scrollBottom - row + 1);
        for (var y = scrollBottom; y >= row + count; y--) screen[y] = screen[y - count];
        for (var y = row; y < row + count; y++) screen[y] = NewLineCells(Columns, ErasedCell);
    }
    private void DeleteLines(int count)
    {
        if (row < scrollTop || row > scrollBottom) return;
        count = Math.Min(count, scrollBottom - row + 1);
        for (var y = row; y <= scrollBottom - count; y++) screen[y] = screen[y + count];
        for (var y = scrollBottom - count + 1; y <= scrollBottom; y++) screen[y] = NewLineCells(Columns, ErasedCell);
    }
    private void DeleteCharacters(int count)
    { Array.Copy(screen[row], column + count, screen[row], column, Columns - column - count); Array.Fill(screen[row], ErasedCell, Columns - count, count); }
    private void InsertCharacters(int count)
    { Array.Copy(screen[row], column, screen[row], column + count, Columns - column - count); Array.Fill(screen[row], ErasedCell, column, count); }
    private void EraseLine(int mode)
    {
        var start = mode == 0 ? column : 0;
        var end = mode == 1 ? column + 1 : Columns;
        Array.Fill(screen[row], ErasedCell, start, end - start);
    }
    private void EraseDisplay(int mode)
    {
        if (mode is 2 or 3) { screen = NewScreen(Columns, Rows); if (mode == 3) scrollback.Clear(); return; }
        EraseLine(mode);
        if (mode == 0) for (var y = row + 1; y < Rows; y++) screen[y] = NewLineCells(Columns, ErasedCell);
        if (mode == 1) for (var y = 0; y < row; y++) screen[y] = NewLineCells(Columns, ErasedCell);
    }

    private void SetStyle(int[] values)
    {
        for (var index = 0; index < values.Length; index++)
        {
            var value = values[index];
            style = value switch
            {
                0 => Blank, 1 => style with { Bold = true }, 3 => style with { Italic = true }, 4 => style with { Underline = true }, 7 => style with { Inverse = true },
                22 => style with { Bold = false }, 23 => style with { Italic = false }, 24 => style with { Underline = false }, 27 => style with { Inverse = false },
                >= 30 and <= 37 => style with { Foreground = Palette(value - 30) }, >= 90 and <= 97 => style with { Foreground = Palette(value - 90 + 8) },
                >= 40 and <= 47 => style with { Background = Palette(value - 40) }, >= 100 and <= 107 => style with { Background = Palette(value - 100 + 8) },
                39 => style with { Foreground = null }, 49 => style with { Background = null }, _ => style
            };
            if (value is 38 or 48 && index + 1 < values.Length)
            {
                uint? color = null;
                if (values[index + 1] == 5 && index + 2 < values.Length) { color = Palette(Math.Clamp(values[index + 2], 0, 255)); index += 2; }
                else if (values[index + 1] == 2 && index + 4 < values.Length)
                { color = (uint)(Math.Clamp(values[index + 2], 0, 255) << 16 | Math.Clamp(values[index + 3], 0, 255) << 8 | Math.Clamp(values[index + 4], 0, 255)); index += 4; }
                if (color is not null) style = value == 38 ? style with { Foreground = color } : style with { Background = color };
            }
        }
    }

    private void SetAlternate(bool enabled)
    {
        if (enabled && primaryScreen is null)
        { primaryScreen = screen; primaryColumn = column; primaryRow = row; screen = NewScreen(Columns, Rows); Move(0, 0); }
        else if (!enabled && primaryScreen is not null)
        { screen = primaryScreen; primaryScreen = null; Move(primaryColumn, primaryRow); }
        scrollTop = 0; scrollBottom = Rows - 1;
    }
    private void Reset()
    { screen = NewScreen(Columns, Rows); primaryScreen = null; style = Blank; Move(0, 0); scrollTop = 0; scrollBottom = Rows - 1; cursorVisible = true; bracketedPaste = false; applicationCursorKeys = false; }
    private static TerminalCell[][] NewScreen(int columns, int rows) => Enumerable.Range(0, rows).Select(_ => NewLineCells(columns, Blank)).ToArray();
    private static TerminalCell[] NewLineCells(int columns, TerminalCell blank) => Enumerable.Repeat(blank, columns).ToArray();
    private static TerminalCell[][] ResizeScreen(TerminalCell[][] previous, int columns, int rows)
    {
        var resized = NewScreen(columns, rows);
        for (var y = 0; y < Math.Min(rows, previous.Length); y++) Array.Copy(previous[y], resized[y], Math.Min(columns, previous[y].Length));
        return resized;
    }
    private static string LineText(TerminalCell[] cells) => string.Concat(cells.Where(x => x.Width != 0).Select(x => x.Text)).TrimEnd();
    private static void ValidateSize(int columns, int rows)
    { if (columns is < 1 or > 1000 || rows is < 1 or > 500) throw new ArgumentOutOfRangeException(nameof(columns), "Terminal viewport exceeds supported bounds."); }
    private static int RuneWidth(Rune rune)
    {
        var v = rune.Value;
        return v is >= 0x1100 and <= 0x115f or >= 0x2e80 and <= 0xa4cf or >= 0xac00 and <= 0xd7a3 or >= 0xf900 and <= 0xfaff or >= 0xfe10 and <= 0xfe6f or >= 0xff01 and <= 0xff60 or >= 0xffe0 and <= 0xffe6 or >= 0x1f300 and <= 0x1faff or >= 0x20000 and <= 0x3ffff ? 2 : 1;
    }
    private static uint Palette(int index)
    {
        uint[] colors = [0x0c0c0c, 0xc50f1f, 0x13a10e, 0xc19c00, 0x0037da, 0x881798, 0x3a96dd, 0xcccccc, 0x767676, 0xe74856, 0x16c60c, 0xf9f1a5, 0x3b78ff, 0xb4009e, 0x61d6d6, 0xf2f2f2];
        if (index < 16) return colors[index];
        if (index >= 232) { var gray = (uint)(8 + (index - 232) * 10); return gray << 16 | gray << 8 | gray; }
        var offset = index - 16;
        static uint Component(int value) => (uint)(value == 0 ? 0 : 55 + value * 40);
        return Component(offset / 36) << 16 | Component(offset / 6 % 6) << 8 | Component(offset % 6);
    }
    private enum ParseState { Ground, Escape, Csi, Osc, OscEscape, Charset }
}
