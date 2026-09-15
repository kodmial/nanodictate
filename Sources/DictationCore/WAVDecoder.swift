import Foundation

// MARK: - Ответственность: декодирование WAV (RIFF/PCM) в Int16-сэмплы
// Батч-распознавание работает с сэмплами (чанки, длительность), поэтому WAV
// разбирается в [Int16], а не отправляется сырыми байтами. Поддерживается
// canonical PCM WAV (и типичные afconvert-продукты с LIST/fact-чанками):
// fmt-чанк (PCM, каналы, sampleRate, битность) + data-чанк; неизвестные
// чанки пропускаются. Не-WAV/не-PCM — nil (вызывающий конвертирует через
// afconvert).

/// Разобранный WAV.
public struct WAVInfo: Equatable {
    public let sampleRate: Int
    public let channels: Int
    /// PCM Int16-сэмплы (по каналам подряд для многоканального).
    public let samples: [Int16]

    public init(sampleRate: Int, channels: Int, samples: [Int16]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }
}

public enum WAVDecoder {

    public static func decodePCM16(_ data: Data) -> WAVInfo? {
        let bytes = [UInt8](data)
        guard bytes.count >= 44 else { return nil }
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF" else { return nil }
        guard String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        // Двигаемся по чанкам: fmt обязателен до data, остальные пропускаем.
        var cursor = 12
        var sampleRate = 0
        var channels = 0
        var bitsPerSample = 0
        var dataOffset = -1
        var dataSize = 0

        while cursor + 8 <= bytes.count {
            let chunkID = String(bytes: bytes[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
            let size = Int(readUInt32LE(bytes, at: cursor + 4))
            let payloadStart = cursor + 8
            guard payloadStart + size <= bytes.count else { return nil }

            switch chunkID {
            case "fmt ":
                guard size >= 16 else { return nil }
                let audioFormat = Int(readUInt16LE(bytes, at: payloadStart))
                guard audioFormat == 1 else { return nil } // PCM only
                channels = Int(readUInt16LE(bytes, at: payloadStart + 2))
                sampleRate = Int(readUInt32LE(bytes, at: payloadStart + 4))
                bitsPerSample = Int(readUInt16LE(bytes, at: payloadStart + 14))
                guard bitsPerSample == 16 else { return nil }
            case "data":
                dataOffset = payloadStart
                dataSize = size
            default:
                break
            }

            cursor = payloadStart + size + (size % 2) // чанки выровнены по 2 байта
        }

        guard sampleRate > 0, channels > 0, dataOffset >= 0, dataSize > 0 else { return nil }
        let sampleCount = dataSize / 2
        guard sampleCount > 0 else { return nil }

        var samples: [Int16] = []
        samples.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            let offset = dataOffset + i * 2
            guard offset + 2 <= bytes.count else { break }
            let value = readUInt16LE(bytes, at: offset)
            samples.append(Int16(bitPattern: value))
        }
        guard samples.count == sampleCount else { return nil }
        return WAVInfo(sampleRate: sampleRate, channels: channels, samples: samples)
    }

    private static func readUInt16LE(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}