import Foundation

/// Кодирование PCM Int16 сэмплов в WAV (RIFF) формат.
public enum WAVEncoder {
    /// Кодирует массив Int16 сэмплов в WAV-файл (mono, 16 бит, указанный sampleRate).
    public static func encode(samples: [Int16], sampleRate: Int = 16000) -> Data {
        let numChannels: Int16 = 1
        let bitsPerSample: Int16 = 16
        let byteRate = Int32(sampleRate) * Int32(numChannels) * Int32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = Int32(samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.reserveCapacity(44 + samples.count * 2)

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt sub-chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) }) // sub-chunk size
        data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) }) // PCM
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data sub-chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        // Резервная ёмкость уже выделена (44 + samples.count * 2): bulk-append
        // сырых байт вместо per-sample append — в разы быстрее на больших чанках
        // (30 c @16 кГц = 480 000 сэмплов = 960 КБ; per-sample append аллоцировал
        // временный Array на каждый сэмпл). Малая endian — native на всех Mac.
        if !samples.isEmpty {
            samples.withUnsafeBytes { raw in
                data.append(contentsOf: raw)
            }
        }

        return data
    }
}