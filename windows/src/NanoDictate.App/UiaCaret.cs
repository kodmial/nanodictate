using System.Runtime.InteropServices;
using NanoDictate.Core;

namespace NanoDictate.App;

/// <summary>
/// Best-effort UI Automation caret lookup for editors that expose the Text
/// pattern. The native GetGUIThreadInfo caret is only a fallback: many modern
/// editors never create a Win32 caret, while UIA returns the insertion range.
/// Failures are silent so placement can always fall back to pointer/screen.
/// </summary>
internal static class UiaCaret
{
    private const int UiaTextPatternId = 10014;
    private static readonly Guid TextPatternIid = new("32eba289-3583-42c9-9c59-3b6d9a1e9b6a");

    public static bool TryGet(out HudPoint point)
    {
        point = default;
        object? automationObject = null;
        object? elementObject = null;
        object? patternObject = null;
        object? rangesObject = null;
        IntPtr patternPointer = IntPtr.Zero;
        try
        {
            automationObject = new CUIAutomation();
            var automation = (IUIAutomation)automationObject;
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
            if (range.GetBoundingRectangles(out var rectangles) < 0 || rectangles == IntPtr.Zero)
            {
                return false;
            }
            return TryReadRectangles(rectangles, out point);
        }
        catch
        {
            point = default;
            return false;
        }
        finally
        {
            if (patternPointer != IntPtr.Zero)
            {
                Marshal.Release(patternPointer);
            }
            Release(rangesObject);
            Release(patternObject);
            Release(elementObject);
            Release(automationObject);
        }
    }

    private static bool TryReadRectangles(IntPtr safeArray, out HudPoint point)
    {
        point = default;
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
                    point = new HudPoint(values[i], values[i + 1] + values[i + 3]);
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
