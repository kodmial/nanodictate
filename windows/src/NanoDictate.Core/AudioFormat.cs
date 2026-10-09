namespace NanoDictate.Core;

/// <summary>
/// Windows device audio format descriptor for the native capture path.
/// The agreed shared-engine ingress is always 16 kHz mono Float32 blocks;
/// this type describes what the device (WASAPI mix format) delivers so the
/// converter can normalize it without dropping initial samples.
/// </summary>
public readonly record struct AudioFormat(
    int SampleRate,
    int Channels,
    int BitsPerSample,
    bool IsFloat)
{
    /// <summary>Agreed shared-engine ingress sample rate.</summary>
    public const int EngineSampleRate = 16000;

    /// <summary>Agreed shared-engine ingress channel count.</summary>
    public const int EngineChannels = 1;

    /// <summary>Typical WASAPI shared-mode mix format (48 kHz stereo float).</summary>
    public static AudioFormat DefaultDevice => new(48000, 2, 32, true);

    /// <summary>True when device frames already match the engine ingress.</summary>
    public bool IsEngineNative =>
        SampleRate == EngineSampleRate && Channels == EngineChannels && IsFloat;

    /// <summary>Validates a device format. Throws <see cref="NanoException"/> on nonsense.</summary>
    public void Validate()
    {
        if (SampleRate <= 0 || SampleRate > 192000)
        {
            throw new NanoException(-1, $"unsupported device sample rate {SampleRate}");
        }
        if (Channels <= 0 || Channels > 8)
        {
            throw new NanoException(-1, $"unsupported device channel count {Channels}");
        }
        if (BitsPerSample != 16 && BitsPerSample != 24 && BitsPerSample != 32)
        {
            throw new NanoException(-1, $"unsupported device bit depth {BitsPerSample}");
        }
    }

    /// <summary>
    /// Short hardware signature (rate + channels) used to detect device
    /// changes that invalidate converter state, mirroring the macOS
    /// hwSignature helper.
    /// </summary>
    public string Signature => $"{SampleRate}Hz-ch{Channels}";

    /// <summary>Expected Float32 frames per engine block at this device rate.</summary>
    public int DeviceFramesPerEngineBlock(int engineBlockSamples)
    {
        if (engineBlockSamples <= 0)
        {
            throw new NanoException(-1, "engine block size must be positive");
        }
        return Math.Max(1, (int)Math.Round((double)engineBlockSamples * SampleRate / EngineSampleRate));
    }
}
