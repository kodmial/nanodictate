using System.Runtime.InteropServices;

namespace NanoDictate.Core;

/// <summary>
/// C-compatible byte buffer owned by the caller.
/// Released with <c>nd_bytes_free</c>. Mirrors <c>NdByteBuffer</c> in
/// <c>Sources/NanoDictateRustFFI/include/nanodictate_core.h</c>.
/// </summary>
[StructLayout(LayoutKind.Sequential)]
internal struct NdByteBuffer
{
    public IntPtr Data;
    public UIntPtr Len;
    public UIntPtr Cap;
}
