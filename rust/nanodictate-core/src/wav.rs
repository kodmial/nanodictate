//! WAV (RIFF/PCM16) encoder and decoder.
//!
//! Ports `WAVEncoder` and `WAVDecoder` from the Swift layer. The encoder
//! output is byte-identical to the Swift implementation for the same inputs
//! (canonical 44-byte header, little-endian PCM16). The decoder accepts the
//! same canonical files the Swift decoder accepts: a `fmt ` chunk (PCM,
//! 16-bit) before the first `data` chunk, unknown chunks skipped, chunks
//! 2-byte aligned.

/// Decoded WAV payload: format plus channel-interleaved Int16 samples.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WavInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: Vec<i16>,
}

/// WAV header metadata without copying samples.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WavPcmHeader {
    pub sample_rate: u32,
    pub channels: u16,
    pub bits_per_sample: u16,
    pub data_offset: usize,
    pub data_size: usize,
}

impl WavPcmHeader {
    pub fn sample_count(&self) -> usize {
        self.data_size / 2
    }
}

/// Encodes Int16 samples as a 16-bit PCM WAV file.
///
/// The default profile is the historic batch profile (mono 16 kHz); callers
/// pass the model audio profile explicitly instead of relying on defaults.
///
/// Returns `None` when the WAV header fields cannot represent the inputs:
/// `sample_rate` or `channels` is zero, `byte_rate` does not fit `u32`,
/// `block_align` does not fit `u16`, or the payload (`36 + bytes`) does not
/// fit the `u32` RIFF/data size fields.
pub fn encode(samples: &[i16], sample_rate: u32, channels: u16) -> Option<Vec<u8>> {
    if sample_rate == 0 || channels == 0 {
        return None;
    }
    let bits_per_sample: u16 = 16;
    let bytes_per_sample = u32::from(bits_per_sample / 8);
    let byte_rate = sample_rate
        .checked_mul(u32::from(channels))?
        .checked_mul(bytes_per_sample)?;
    let block_align = channels.checked_mul(bits_per_sample / 8)?;
    let payload_bytes = samples.len().checked_mul(2)?;
    let data_size = u32::try_from(payload_bytes).ok()?;
    let file_size = data_size.checked_add(36)?;

    let mut out = Vec::with_capacity(44usize.checked_add(payload_bytes)?);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&file_size.to_le_bytes());
    out.extend_from_slice(b"WAVE");
    out.extend_from_slice(b"fmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&channels.to_le_bytes());
    out.extend_from_slice(&sample_rate.to_le_bytes());
    out.extend_from_slice(&byte_rate.to_le_bytes());
    out.extend_from_slice(&block_align.to_le_bytes());
    out.extend_from_slice(&bits_per_sample.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_size.to_le_bytes());
    for s in samples {
        out.extend_from_slice(&s.to_le_bytes());
    }
    Some(out)
}

fn read_u16_le(data: &[u8], at: usize) -> u16 {
    u16::from_le_bytes([data[at], data[at + 1]])
}

fn read_u32_le(data: &[u8], at: usize) -> u32 {
    u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]])
}

fn is_riff_wave_prefix(data: &[u8]) -> bool {
    data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WAVE"
}

/// Parses the WAV header (RIFF/fmt/data) without copying samples.
///
/// Only canonical PCM 16-bit is accepted. Unknown chunks (LIST/fact/...)
/// are skipped. The `fmt ` chunk must come before `data`; of several `data`
/// chunks the first one wins. Only the window covering chunks up to (and
/// including the header of) the `data` chunk must be present: the payload
/// itself is not required, only its offset and size are remembered.
pub fn pcm_header(data: &[u8]) -> Option<WavPcmHeader> {
    if data.len() < 44 || !is_riff_wave_prefix(data) {
        return None;
    }
    let mut cursor = 12usize;
    let mut sample_rate = 0u32;
    let mut channels = 0u16;
    let mut bits_per_sample = 0u16;
    let mut have_fmt = false;
    let mut data_offset: Option<usize> = None;
    let mut data_size = 0usize;

    while cursor + 8 <= data.len() {
        let chunk_id = &data[cursor..cursor + 4];
        let size = read_u32_le(data, cursor + 4) as usize;
        let payload_start = cursor + 8;
        if chunk_id == b"data" {
            if !have_fmt {
                return None;
            }
            data_offset = Some(payload_start);
            data_size = size;
            break;
        }
        if payload_start.checked_add(size)? > data.len() {
            return None;
        }
        if chunk_id == b"fmt " {
            if size < 16 {
                return None;
            }
            let audio_format = read_u16_le(data, payload_start);
            if audio_format != 1 {
                return None;
            }
            channels = read_u16_le(data, payload_start + 2);
            sample_rate = read_u32_le(data, payload_start + 4);
            bits_per_sample = read_u16_le(data, payload_start + 14);
            if bits_per_sample != 16 {
                return None;
            }
            have_fmt = true;
        }
        cursor = payload_start + size + (size % 2);
    }

    let data_offset = data_offset?;
    if !have_fmt || sample_rate == 0 || channels == 0 || data_size == 0 {
        return None;
    }
    if data_offset > data.len() {
        return None;
    }
    Some(WavPcmHeader {
        sample_rate,
        channels,
        bits_per_sample,
        data_offset,
        data_size,
    })
}

/// Decodes a whole WAV file into Int16 samples.
///
/// Unlike [`pcm_header`], the declared payload must be fully present:
/// a truncated file (declared size larger than the available bytes)
/// yields `None`.
pub fn decode_pcm16(data: &[u8]) -> Option<WavInfo> {
    let header = pcm_header(data)?;
    let sample_count = header.sample_count();
    if sample_count == 0 {
        return None;
    }
    if header.data_offset.checked_add(sample_count * 2)? > data.len() {
        return None;
    }
    let mut samples = Vec::with_capacity(sample_count);
    for i in 0..sample_count {
        let off = header.data_offset + i * 2;
        samples.push(i16::from_le_bytes([data[off], data[off + 1]]));
    }
    Some(WavInfo {
        sample_rate: header.sample_rate,
        channels: header.channels,
        samples,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_header_matches_canonical_layout() {
        let wav = encode(&[0, 1, -1, 32767, -32768], 16000, 1).expect("valid inputs must encode");
        assert_eq!(wav.len(), 44 + 10);
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
        assert_eq!(&wav[12..16], b"fmt ");
        assert_eq!(
            u32::from_le_bytes([wav[4], wav[5], wav[6], wav[7]]),
            36 + 10
        );
        assert_eq!(u16::from_le_bytes([wav[20], wav[21]]), 1); // PCM
        assert_eq!(u16::from_le_bytes([wav[22], wav[23]]), 1); // mono
        assert_eq!(
            u32::from_le_bytes([wav[24], wav[25], wav[26], wav[27]]),
            16000 // sample rate
        );
        assert_eq!(
            u32::from_le_bytes([wav[28], wav[29], wav[30], wav[31]]),
            32000 // byte rate: 16000 * 1 * 2
        );
        assert_eq!(&wav[36..40], b"data");
        // Payload is native little-endian Int16.
        assert_eq!(i16::from_le_bytes([wav[44], wav[45]]), 0);
        assert_eq!(i16::from_le_bytes([wav[46], wav[47]]), 1);
        assert_eq!(i16::from_le_bytes([wav[52], wav[53]]), -32768);
    }

    #[test]
    fn encode_empty_payload() {
        let wav = encode(&[], 16000, 1).expect("valid inputs must encode");
        assert_eq!(wav.len(), 44);
        assert_eq!(u32::from_le_bytes([wav[40], wav[41], wav[42], wav[43]]), 0);
    }

    #[test]
    fn encode_rejects_header_overflow_inputs() {
        // u32::MAX sample rate with stereo channels overflows u32 byte_rate.
        assert!(encode(&[1, 2, 3], u32::MAX, u16::MAX).is_none());
        assert!(encode(&[1, 2, 3], u32::MAX, 2).is_none());
        // block_align overflows u16 when channels * 2 exceeds u16::MAX.
        assert!(encode(&[1, 2, 3], 16000, u16::MAX).is_none());
        // Zero rate/channels have no valid header representation.
        assert!(encode(&[1, 2, 3], 0, 1).is_none());
        assert!(encode(&[1, 2, 3], 16000, 0).is_none());
    }

    #[test]
    fn roundtrip_encode_decode() {
        let samples: Vec<i16> = (0..16000).map(|i| ((i % 256) as i16) * 100).collect();
        let wav = encode(&samples, 16000, 1).expect("valid inputs must encode");
        let info = decode_pcm16(&wav).expect("roundtrip must decode");
        assert_eq!(info.sample_rate, 16000);
        assert_eq!(info.channels, 1);
        assert_eq!(info.samples, samples);
    }

    #[test]
    fn header_prefix_without_payload() {
        let samples = vec![7i16; 100];
        let wav = encode(&samples, 16000, 1).expect("valid inputs must encode");
        let prefix = &wav[..44];
        let header = pcm_header(prefix).expect("header visible in prefix");
        assert_eq!(header.sample_count(), 100);
        assert!(decode_pcm16(prefix).is_none());
    }

    #[test]
    fn rejects_non_wav_and_non_pcm() {
        assert!(decode_pcm16(b"not a wav file at all, definitely too short!!").is_none());
        let mut wav = encode(&[1, 2, 3], 16000, 1).expect("valid inputs must encode");
        // Corrupt audioFormat (offset 20) to 3 (float).
        wav[20] = 3;
        assert!(decode_pcm16(&wav).is_none());
    }

    #[test]
    fn data_before_fmt_rejected() {
        // Minimal hand-built file with data chunk first.
        let mut f = Vec::new();
        f.extend_from_slice(b"RIFF");
        f.extend_from_slice(&28u32.to_le_bytes());
        f.extend_from_slice(b"WAVE");
        f.extend_from_slice(b"data");
        f.extend_from_slice(&4u32.to_le_bytes());
        f.extend_from_slice(&[1, 0, 2, 0]);
        f.extend_from_slice(b"fmt ");
        f.extend_from_slice(&16u32.to_le_bytes());
        f.extend_from_slice(&[1, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 16, 0]);
        assert!(pcm_header(&f).is_none());
    }

    #[test]
    fn skips_unknown_chunks_with_odd_size_padding() {
        let samples = vec![5i16, 6, 7];
        let canonical = encode(&samples, 16000, 1).expect("valid inputs must encode");
        // Insert a 3-byte JUNK chunk (odd size + 1 pad byte) between fmt and data.
        let mut f = Vec::new();
        f.extend_from_slice(&canonical[..36]);
        f.extend_from_slice(b"JUNK");
        f.extend_from_slice(&3u32.to_le_bytes());
        f.extend_from_slice(&[9, 9, 9, 0]);
        f.extend_from_slice(&canonical[36..]);
        // Fix the RIFF size.
        let size = (f.len() - 8) as u32;
        f[4..8].copy_from_slice(&size.to_le_bytes());
        let info = decode_pcm16(&f).expect("unknown chunks must be skipped");
        assert_eq!(info.samples, samples);
    }
}
