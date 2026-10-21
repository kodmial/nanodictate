using System.Runtime.InteropServices;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// Best-effort UI Automation caret lookup for editors that expose the Text
/// pattern. The native GetGUIThreadInfo caret is only a fallback: many modern
/// editors never create a Win32 caret, while UIA returns the insertion range.
/// Failures are silent so placement can always fall back to pointer/screen.
/// UIA runs on one dedicated MTA worker (never on the HUD dispatcher) with a
/// reused <c>CUIAutomation</c> instance, because calling UIA synchronously on
/// the UI thread can make the application unresponsive, especially against its
/// own windows.
/// </summary>
internal static class UiaCaret
{
    private const int UiaTextPatternId = 10014;
    private static readonly Guid TextPatternIid = new("32eba289-3583-42c9-9c59-3b6d9a1e9b6a");
    private static readonly object WorkerGate = new();
    private static readonly AutoResetEvent WorkerSignal = new(false);
    private static Thread? _worker;
    private static bool _workerRunning;
    private static bool _requestPending;
    private static ulong _requestToken;
    private static Action<ulong, HudCaret?>? _requestCompleted;

    /// <summary>
    /// Queues the latest caret lookup. Requests received while one lookup is
    /// running replace any earlier queued request, so at most one runs at a
    /// time and stale tokens can be ignored by the caller.
    /// </summary>
    public static void Request(ulong token, Action<ulong, HudCaret?> completed)
    {
        lock (WorkerGate)
        {
            _requestToken = token;
            _requestCompleted = completed;
            _requestPending = true;
            if (_worker is null)
            {
                _workerRunning = true;
                _worker = new Thread(WorkerLoop)
                {
                    IsBackground = true,
                    Name = "NanoDictate UIA caret",
                };
                _worker.SetApartmentState(ApartmentState.MTA);
                _worker.Start();
            }
        }
        WorkerSignal.Set();
    }

    /// <summary>Stops the worker without joining it (never blocks the dispatcher).</summary>
    public static void Stop()
    {
        lock (WorkerGate)
        {
            _workerRunning = false;
            _requestPending = false;
            _requestCompleted = null;
        }
        WorkerSignal.Set();
    }

    private static void WorkerLoop()
    {
        object? automationObject = null;
        try
        {
            automationObject = new CUIAutomation();
            var automation = (IUIAutomation)automationObject;
            while (true)
            {
                WorkerSignal.WaitOne();
                ulong token;
                Action<ulong, HudCaret?>? completed;
                lock (WorkerGate)
                {
                    if (!_workerRunning)
                    {
                        break;
                    }
                    if (!_requestPending)
                    {
                        continue;
                    }
                    _requestPending = false;
                    token = _requestToken;
                    completed = _requestCompleted;
                }

                HudCaret? caretResult = null;
                if (!WindowsInterop.ForegroundWindowBelongsToCurrentProcess()
                    && TryGet(automation, out var caret))
                {
                    caretResult = caret;
                }
                completed?.Invoke(token, caretResult);
            }
        }
        catch
        {
            // A failed worker leaves placement on the native/pointer fallback.
        }
        finally
        {
            if (automationObject is not null && Marshal.IsComObject(automationObject))
            {
                Marshal.ReleaseComObject(automationObject);
            }
            lock (WorkerGate)
            {
                _worker = null;
                _workerRunning = false;
            }
        }
    }

    private static bool TryGet(IUIAutomation automation, out HudCaret caret)
    {
        caret = default;
        object? elementObject = null;
        object? patternObject = null;
        object? rangesObject = null;
        object? rangeObject = null;
        IntPtr patternPointer = IntPtr.Zero;
        try
        {
            if (automation.GetFocusedElement(out var element) < 0 || element is null)
            {
                return false;
            }
            elementObject = element;
            var textPatternIid = TextPatternIid;
            if (element.GetCurrentPatternAs(UiaTextPatternId, ref textPatternIid, out patternPointer) < 0
                || patternPointer == IntPtr.Zero)
            {
                return false;
            }
            patternObject = Marshal.GetObjectForIUnknown(patternPointer);
            Marshal.Release(patternPointer);
            patternPointer = IntPtr.Zero;
            var pattern = (IUIAutomationTextPattern)patternObject;
            if (pattern.GetSelection(out var ranges) < 0 || ranges is null)
            {
                return false;
            }
            rangesObject = ranges;
            if (ranges.get_Length(out var length) < 0 || length <= 0)
            {
                return false;
            }
            // The first selection is the insertion point for a collapsed
            // caret; multi-selection uses the first range, matching UIA.
            if (ranges.GetElement(0, out var range) < 0 || range is null)
            {
                return false;
            }
            rangeObject = range;
            if (range.GetBoundingRectangles(out var rectangles) < 0 || rectangles == IntPtr.Zero)
            {
                return false;
            }
            if (TryReadRectangles(rectangles, out caret))
            {
                return true;
            }
            // A collapsed caret is a degenerate range, and UIA returns no
            // rectangle for it. The range is a copy, so expanding it to one
            // character (TextUnit_Character = 0) does not change the user's selection.
            if (range.ExpandToEnclosingUnit(0) < 0
                || range.GetBoundingRectangles(out var expanded) < 0
                || expanded == IntPtr.Zero)
            {
                return false;
            }
            return TryReadRectangles(expanded, out caret);
        }
        catch
        {
            caret = default;
            return false;
        }
        finally
        {
            if (patternPointer != IntPtr.Zero)
            {
                Marshal.Release(patternPointer);
            }
            Release(rangeObject);
            Release(rangesObject);
            Release(patternObject);
            Release(elementObject);
        }
    }

    private static bool TryReadRectangles(IntPtr safeArray, out HudCaret caret)
    {
        caret = default;
        try
        {
            if (SafeArrayGetDim(safeArray) < 1
                || SafeArrayGetLBound(safeArray, 1, out var lower) < 0
                || SafeArrayGetUBound(safeArray, 1, out var upper) < 0)
            {
                return false;
            }
            var count = upper - lower + 1;
            if (count < 4)
            {
                return false;
            }
            if (SafeArrayAccessData(safeArray, out var data) < 0 || data == IntPtr.Zero)
            {
                return false;
            }
            try
            {
                var values = new double[count];
                Marshal.Copy(data, values, 0, count);
                // GetBoundingRectangles returns left, top, width, height per
                // visible line. A collapsed caret range is normally one rect;
                // for a selection, the last visible rect is the insertion end.
                for (var i = count - 4; i >= 0; i -= 4)
                {
                    if (values[i + 2] <= 0 && values[i + 3] <= 0)
                    {
                        continue;
                    }
                    caret = new HudCaret(
                        new HudPoint(values[i], values[i + 1] + values[i + 3]),
                        Math.Max(0, values[i + 3]));
                    return true;
                }
            }
            finally
            {
                _ = SafeArrayUnaccessData(safeArray);
            }
        }
        finally
        {
            _ = SafeArrayDestroy(safeArray);
        }
        return false;
    }

    private static void Release(object? value)
    {
        if (value is not null && Marshal.IsComObject(value))
        {
            Marshal.ReleaseComObject(value);
        }
    }

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetDim(IntPtr safeArray);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetLBound(IntPtr safeArray, uint dimension, out int bound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayGetUBound(IntPtr safeArray, uint dimension, out int bound);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayAccessData(IntPtr safeArray, out IntPtr data);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayUnaccessData(IntPtr safeArray);

    [DllImport("oleaut32.dll")]
    private static extern int SafeArrayDestroy(IntPtr safeArray);

    [ComImport]
    [Guid("ff48dba4-60ef-4201-aa87-54103eef594e")]
    private class CUIAutomation
    {
    }

    [ComImport]
    [Guid("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomation
    {
        [PreserveSig]
        int CompareElements(IntPtr first, IntPtr second, out int areSame);

        [PreserveSig]
        int CompareRuntimeIds(IntPtr first, IntPtr second, out int areSame);

        [PreserveSig]
        int GetRootElement(out IUIAutomationElement root);

        [PreserveSig]
        int ElementFromHandle(IntPtr hwnd, out IUIAutomationElement element);

        [PreserveSig]
        int ElementFromPoint(IntPtr point, out IUIAutomationElement element);

        [PreserveSig]
        int GetFocusedElement(out IUIAutomationElement element);
    }

    [ComImport]
    [Guid("d22108aa-8ac5-49a5-837b-37bbb3d7591e")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationElement
    {
        [PreserveSig]
        int SetFocus();

        [PreserveSig]
        int GetRuntimeId(out IntPtr runtimeId);

        [PreserveSig]
        int FindFirst(int scope, IntPtr condition, out IntPtr found);

        [PreserveSig]
        int FindAll(int scope, IntPtr condition, out IntPtr found);

        [PreserveSig]
        int FindFirstBuildCache(int scope, IntPtr condition, IntPtr cacheRequest, out IntPtr found);

        [PreserveSig]
        int FindAllBuildCache(int scope, IntPtr condition, IntPtr cacheRequest, out IntPtr found);

        [PreserveSig]
        int BuildUpdatedCache(IntPtr cacheRequest, out IntPtr updated);

        [PreserveSig]
        int GetCurrentPropertyValue(int propertyId, out IntPtr value);

        [PreserveSig]
        int GetCurrentPropertyValueEx(int propertyId, int ignoreDefaultValue, out IntPtr value);

        [PreserveSig]
        int GetCachedPropertyValue(int propertyId, out IntPtr value);

        [PreserveSig]
        int GetCachedPropertyValueEx(int propertyId, int ignoreDefaultValue, out IntPtr value);

        [PreserveSig]
        int GetCurrentPatternAs(int patternId, ref Guid iid, out IntPtr patternObject);

        [PreserveSig]
        int GetCachedPatternAs(int patternId, ref Guid iid, out IntPtr patternObject);

        [PreserveSig]
        int GetCurrentPattern(int patternId, out IntPtr patternObject);
    }

    [ComImport]
    [Guid("32eba289-3583-42c9-9c59-3b6d9a1e9b6a")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationTextPattern
    {
        [PreserveSig]
        int RangeFromPoint(IntPtr point, out IntPtr range);

        [PreserveSig]
        int RangeFromChild(IntPtr child, out IntPtr range);

        [PreserveSig]
        int GetSelection(out IUIAutomationTextRangeArray ranges);

        [PreserveSig]
        int GetVisibleRanges(out IUIAutomationTextRangeArray ranges);

        [PreserveSig]
        int get_DocumentRange(out IUIAutomationTextRange range);

        [PreserveSig]
        int get_SupportedTextSelection(out int supported);
    }

    [ComImport]
    [Guid("ce4ae76a-e717-4c98-81ea-47371d028eb6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationTextRangeArray
    {
        [PreserveSig]
        int get_Length(out int length);

        [PreserveSig]
        int GetElement(int index, out IUIAutomationTextRange element);
    }

    [ComImport]
    [Guid("a543cc6a-f4ae-494b-8239-c814481187a8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IUIAutomationTextRange
    {
        [PreserveSig]
        int Clone(out IntPtr clonedRange);

        [PreserveSig]
        int Compare(IUIAutomationTextRange range, out int areSame);

        [PreserveSig]
        int CompareEndpoints(int sourceEndpoint, IUIAutomationTextRange range, int targetEndpoint, out int comparison);

        [PreserveSig]
        int ExpandToEnclosingUnit(int unit);

        [PreserveSig]
        int FindAttribute(int attribute, IntPtr value, int backward, out IntPtr found);

        [PreserveSig]
        int FindText(IntPtr text, int backward, int ignoreCase, out IntPtr found);

        [PreserveSig]
        int GetAttributeValue(int attribute, out IntPtr value);

        [PreserveSig]
        int GetBoundingRectangles(out IntPtr rectangles);
    }
}
