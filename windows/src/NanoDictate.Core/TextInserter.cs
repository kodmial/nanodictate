using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>
/// Sink for synthesized input. Production uses SendInput on Windows; tests
/// use a recording fake. Keeps Unicode/Cyrillic/emoji handling identical:
/// one logical chunk in, grapheme-preserving output out.
/// </summary>
public interface IInputSender
{
    void SendUnicodeChunk(string chunk);
    void SendBackspaces(int graphemeCount);
    void SendEnter();
}

/// <summary>Sleep abstraction so chunk pauses are countable in tests.</summary>
public interface ISleeper
{
    void SleepMicroseconds(int microseconds);
}

public sealed class ThreadSleeper : ISleeper
{
    public void SleepMicroseconds(int microseconds) => Thread.Sleep((int)Math.Ceiling(microseconds / 1000.0));
}

/// <summary>
/// Direct Unicode text insertion through Windows SendInput
/// (KEYEVENTF_UNICODE), the Windows counterpart of macOS CGEvent
/// keyboardSetUnicodeString insertion. Each UTF-16 code unit is sent as a
/// key-down/key-up pair so surrogate pairs (emoji), Cyrillic, and combining
/// marks survive; chunking (see <see cref="TextChunker"/>) keeps long
/// insertions responsive with a 5 ms pause between chunks only.
/// Undo erases exactly the inserted grapheme count with Backspace presses in
/// matching chunks; synthetic Enter is a VK_RETURN down/up pair tagged with
/// <see cref="SyntheticEnterMarker.Token"/> so the hotkey hook ignores it.
/// </summary>
public sealed class TextInserter
{
    public const int DelayMicroseconds = 5000;

    private readonly IInputSender _sender;
    private readonly ISleeper _sleeper;

    public TextInserter(IInputSender sender, ISleeper? sleeper = null)
    {
        _sender = sender ?? throw new ArgumentNullException(nameof(sender));
        _sleeper = sleeper ?? new ThreadSleeper();
    }

    /// <summary>Inserts text at the caret. Empty input is a no-op.</summary>
    public void Insert(string text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return;
        }
        var chunks = TextChunker.Chunk(text);
        for (var i = 0; i < chunks.Count; i++)
        {
            _sender.SendUnicodeChunk(chunks[i]);
            if (i < chunks.Count - 1)
            {
                _sleeper.SleepMicroseconds(DelayMicroseconds);
            }
        }
    }

    /// <summary>
    /// Step-by-step dictation: appends the next segment at the end of the
    /// already inserted text (the caret stays at the end after insertion).
    /// </summary>
    public void Append(string text) => Insert(text);

    /// <summary>
    /// Final pass: replaces the already-inserted range <paramref name="oldText"/>
    /// with <paramref name="newText"/>. Equal inputs are a no-op; an empty old
    /// range types only. Backspace count uses grapheme clusters (emoji-safe).
    /// </summary>
    public void ReplaceRange(string oldText, string newText)
    {
        if (oldText == newText)
        {
            return;
        }
        if (oldText.Length == 0)
        {
            Insert(newText);
            return;
        }
        DeleteGraphemes(TextChunker.CountTextElements(oldText));
        Insert(newText);
    }

    /// <summary>
    /// Erases <paramref name="graphemeCount"/> graphemes with Backspace in
    /// <see cref="TextChunker.ChunkSize"/> batches. Non-positive counts are
    /// a no-op (mirrors macOS delete(count:) clamping).
    /// </summary>
    public void DeleteGraphemes(int graphemeCount)
    {
        if (graphemeCount < 1)
        {
            return;
        }
        var remaining = graphemeCount;
        while (remaining > 0)
        {
            var batch = Math.Min(remaining, TextChunker.ChunkSize);
            _sender.SendBackspaces(batch);
            remaining -= batch;
            if (remaining > 0)
            {
                _sleeper.SleepMicroseconds(DelayMicroseconds);
            }
        }
    }

    /// <summary>Erases exactly the graphemes of an inserted string.</summary>
    public void DeleteText(string insertedText) =>
        DeleteGraphemes(TextChunker.CountTextElements(insertedText));

    /// <summary>Posts one synthetic Enter (Return down/up).</summary>
    public void PostReturn() => _sender.SendEnter();
}

/// <summary>
/// Windows SendInput implementation of <see cref="IInputSender"/>.
/// Windows only: every method throws
/// <see cref="PlatformNotSupportedException"/> on other platforms instead of
/// silently dropping keystrokes.
/// </summary>
public sealed class WindowsInputSender : IInputSender
{
    private const ushort VkBack = 0x08;
    private const ushort VkReturn = 0x0D;
    private const uint KeyeventfKeyup = 0x0002;
    private const uint KeyeventfUnicode = 0x0004;
    private const uint KeyeventfScancode = 0x0008;
    private const uint InputKeyboard = 1;

    public void SendUnicodeChunk(string chunk)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Direct Unicode insertion requires Windows (SendInput).");
        }
        if (string.IsNullOrEmpty(chunk))
        {
            return;
        }
        var inputs = new Input[chunk.Length * 2];
        var index = 0;
        foreach (var unit in chunk)
        {
            inputs[index++] = UnicodeInput(unit, false);
            inputs[index++] = UnicodeInput(unit, true);
        }
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            throw new NanoException(Marshal.GetLastWin32Error(), $"SendInput delivered {sent} of {inputs.Length} Unicode events");
        }
    }

    public void SendBackspaces(int graphemeCount)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Backspace undo requires Windows (SendInput).");
        }
        if (graphemeCount < 1)
        {
            return;
        }
        for (var i = 0; i < graphemeCount; i++)
        {
            var inputs = new[] { VirtualInput(VkBack, false), VirtualInput(VkBack, true) };
            var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
            if (sent != inputs.Length)
            {
                throw new NanoException(Marshal.GetLastWin32Error(), "SendInput failed to deliver Backspace events");
            }
        }
    }

    public void SendEnter()
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("Synthetic Enter requires Windows (SendInput).");
        }
        var inputs = new[]
        {
            VirtualInput(VkReturn, false, SyntheticEnterMarker.Token),
            VirtualInput(VkReturn, true, SyntheticEnterMarker.Token),
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Input>());
        if (sent != inputs.Length)
        {
            throw new NanoException(Marshal.GetLastWin32Error(), "SendInput failed to deliver synthetic Enter");
        }
    }

    private static Input UnicodeInput(char unit, bool keyUp) => new()
    {
        Type = InputKeyboard,
        Data = new InputData
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = 0,
                ScanCode = unit,
                Flags = KeyeventfUnicode | (keyUp ? KeyeventfKeyup : 0),
                Time = 0,
                ExtraInfo = IntPtr.Zero,
            },
        },
    };

    private static Input VirtualInput(ushort vk, bool keyUp, uint extraInfo = 0) => new()
    {
        Type = InputKeyboard,
        Data = new InputData
        {
            Keyboard = new KeyboardInput
            {
                VirtualKey = vk,
                ScanCode = 0,
                Flags = (keyUp ? KeyeventfKeyup : 0) | KeyeventfScancode,
                Time = 0,
                ExtraInfo = new IntPtr(unchecked((nint)extraInfo)),
            },
        },
    };

    [StructLayout(LayoutKind.Sequential)]
    private struct Input
    {
        public uint Type;
        public InputData Data;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputData
    {
        [FieldOffset(0)]
        public KeyboardInput Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort VirtualKey;
        public ushort ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, [In] Input[] pInputs, int cbSize);
}
