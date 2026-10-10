namespace NanoDictate.Core;

/// <summary>
/// Converts device-format Float32 frames into the agreed block-oriented
/// shared-engine ingress: 16 kHz mono Float32 blocks.
///
/// Semantics (mirrors the macOS AVAudioConverter normalization):
/// <list type="bullet">
/// <item>Multi-channel input is downmixed by arithmetic mean (no channel is dropped).</item>
/// <item>Arbitrary device rates are resampled with linear interpolation.</item>
/// <item>The first device frame is converted immediately: no warm-up
/// frames are dropped, so immediate speech survives (P0 first-word).</item>
/// <item>Fractional resample position carries across <see cref="Convert"/>
/// calls; <see cref="Flush"/> emits the trailing remainder at stop.</item>
/// <item>Steady-state conversion reuses the caller-provided output buffer;
/// only the returned count is authoritative. No per-callback allocation
/// beyond the output block itself.</item>
/// </list>
/// No Rust algorithm is reimplemented here: this is pure transport
/// normalization. VAD, gain, auto-stop, and segmentation stay in Rust.
/// </summary>
public sealed class AudioFormatConverter
{
    private readonly AudioFormat _device;
    private readonly double _step;
    private double _position;
    private float _lastMono;
    private bool _hasLast;
    private long _deviceFramesConsumed;
    private long _engineSamplesEmitted;

    public AudioFormatConverter(AudioFormat device)
    {
        device.Validate();
        if (!device.IsFloat)
        {
            throw new NanoException(-1, "only Float32 device frames are supported on this path");
        }
        _device = device;
        _step = (double)device.SampleRate / AudioFormat.EngineSampleRate;
        _position = 0.0;
    }

    public AudioFormat Device => _device;

    public long DeviceFramesConsumed => _deviceFramesConsumed;

    public long EngineSamplesEmitted => _engineSamplesEmitted;

    /// <summary>Resets resample state for a new session (same device).</summary>
    public void Reset()
    {
        _position = 0.0;
        _hasLast = false;
        _lastMono = 0.0f;
        _deviceFramesConsumed = 0;
        _engineSamplesEmitted = 0;
    }

    /// <summary>
    /// Converts interleaved device Float32 frames to mono engine samples.
    /// Returns the number of engine samples written to <paramref name="output"/>.
    /// </summary>
    public int Convert(ReadOnlySpan<float> interleavedDeviceFrames, int frameCount, Span<float> output)
    {
        if (frameCount < 0 || frameCount * _device.Channels > interleavedDeviceFrames.Length)
        {
            throw new NanoException(-1, "device frame count exceeds input span");
        }
        if (frameCount == 0)
        {
            return 0;
        }

        // Validate capacity before mutating any conversion state: a short
        // span must fail loudly instead of silently dropping frames or
        // corrupting the resample phase.
        int required;
        if (_device.SampleRate == AudioFormat.EngineSampleRate)
        {
            required = frameCount;
        }
        else if (_position >= frameCount)
        {
            required = 0;
        }
        else
        {
            required = (int)Math.Ceiling((frameCount - _position) / _step);
        }
        if (output.Length < required)
        {
            throw new NanoException(-1, "output span too small for converted block");
        }

        // Downmix to mono first (bounded scratch on the stack for small
        // blocks; heap only for very large device callbacks).
        Span<float> mono = frameCount <= 2048
            ? stackalloc float[frameCount]
            : new float[frameCount];
        for (var f = 0; f < frameCount; f++)
        {
            var baseIndex = f * _device.Channels;
            float sum = 0.0f;
            for (var c = 0; c < _device.Channels; c++)
            {
                sum += interleavedDeviceFrames[baseIndex + c];
            }
            mono[f] = sum / _device.Channels;
        }
        _deviceFramesConsumed += frameCount;

        int written = 0;
        if (_device.SampleRate == AudioFormat.EngineSampleRate)
        {
            var n = Math.Min(frameCount, output.Length);
            mono.Slice(0, n).CopyTo(output);
            _lastMono = mono[n - 1];
            _hasLast = true;
            written = n;
        }
        else
        {
            // Linear resample over the mono stream. _position is the
            // device-frame index of the next engine sample; it carries
            // across Convert calls so block boundaries neither duplicate
            // nor drop (the boundary interpolation holds the last frame
            // when the right neighbor belongs to the next callback).
            while (written < output.Length)
            {
                var pos = _position;
                if (pos >= frameCount)
                {
                    break;
                }
                var i0 = (int)pos; // floor; pos is always >= 0
                var frac = (float)(pos - i0);
                var left = mono[i0];
                var right = i0 + 1 < frameCount ? mono[i0 + 1] : mono[i0];
                output[written] = left + ((right - left) * frac);
                written++;
                _position += _step;
            }
            _position -= frameCount;
            _lastMono = mono[frameCount - 1];
            _hasLast = true;
        }

        _engineSamplesEmitted += written;
        return written;
    }

    /// <summary>
    /// Emits the trailing resample remainder at stop (at most one sample).
    /// Returns samples written; 0 when nothing is pending.
    /// </summary>
    public int Flush(Span<float> output)
    {
        if (output.Length == 0 || !_hasLast)
        {
            return 0;
        }
        // A fractional position in (0, 1) means the last device frame
        // contributes one more interpolated engine sample.
        if (_position > 0.0 && _position < 1.0)
        {
            output[0] = _lastMono;
            _position = 0.0;
            _engineSamplesEmitted += 1;
            return 1;
        }
        return 0;
    }
}
