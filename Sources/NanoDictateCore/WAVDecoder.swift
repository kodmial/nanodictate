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

/// Метаданные WAV-файла: fmt+data (без копирования сэмплов).
public struct WAVPCMHeader: Equatable {
  public let sampleRate: Int
  public let channels: Int
  public let bitsPerSample: Int
  public let dataOffset: Int
  public let dataSize: Int
  public var sampleCount: Int {
    dataSize / 2
  }
}

public enum WAVDecoder {
  /// Разбирает ЗАГОЛОВОК WAV (RIFF/fmt/data: PCM, каналы, sampleRate, битность,
  /// оффсет и размер PCM-данных) БЕЗ копирования сэмплов. Только canonical PCM
  /// 16-бит (как decodePCM16); неизвестные чанки (LIST/fact/...) пропускаются.
  /// Двигается по цепочке чанков (4 байта id + 4 байта size, выравнивание по
  /// 2 байта — нечётный payload дополняется байтом паддинга). Требования
  /// canonical layout: fmt-чанк обязан идти ДО data (data раньше fmt → nil);
  /// из нескольких data-чанков учитывается ПЕРВЫЙ, остальные игнорируются.
  /// Для файла достаточно окна, покрывающего чанки ДО data: заголовок
  /// самого data-чанка (id+size, 8 байт) должен быть в окне, его payload
  /// (весь звук) в окне НЕ обязателен — запоминаются только оффсет и размер.
  public static func pcmHeader(in data: Data) -> WAVPCMHeader? {
    guard data.count >= 44, isRIFFWAVEPrefix(data) else { return nil }

    // Двигаемся по чанкам: fmt обязателен до data, остальные пропускаем.
    var cursor = 12
    var sampleRate = 0
    var channels = 0
    var bitsPerSample = 0
    var dataOffset = -1
    var dataSize = 0

    while cursor + 8 <= data.count {
      let chunkID = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
      let size = Int(readUInt32LE(data, at: cursor + 4))
      let payloadStart = cursor + 8

      if chunkID == "data" {
        // data-чанк найден: дальше можно не идти. ПЕРВАЯ data wins —
        // последующие data-чанки (нестандартные файлы) игнорируются.
        // Payload может быть сколь угодно большим (весь звук) и в окне
        // не нужен — берём только оффсет и размер из заголовка.
        dataOffset = payloadStart
        dataSize = size
        break
      }

      // Для остальных чанков нужно знать payload, чтобы перешагнуть через
      // него к следующему заголовку.
      guard payloadStart + size <= data.count else { return nil }

      switch chunkID {
      case "fmt ":
        guard let fmt = readFmtChunk(data, payloadStart: payloadStart, size: size) else {
          return nil
        }
        channels = fmt.channels
        sampleRate = fmt.sampleRate
        bitsPerSample = fmt.bitsPerSample
      default:
        break
      }

      cursor = payloadStart + size + (size % 2)  // чанки выровнены по 2 байта
    }

    guard sampleRate > 0, channels > 0, dataOffset >= 0, dataSize > 0 else { return nil }
    // Заголовок data-чанка (id+size) гарантированно в окне условием цикла
    // (dataOffset = курсор найденного чанка + 8 ≤ data.count); сам payload
    // в окне НЕ обязателен — для файла достаточно префикса до data.
    guard dataOffset <= data.count else { return nil }
    return WAVPCMHeader(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      dataOffset: dataOffset,
      dataSize: dataSize
    )
  }

  /// Декодирует WAV ЦЕЛИКОМ в [Int16]. В отличие от pcmHeader (работает по
  /// префиксу) требует, чтобы payload data-чанка полностью присутствовал в
  /// буфере: объявленный dataSize больше фактического → nil (усечённый WAV).
  public static func decodePCM16(_ data: Data) -> WAVInfo? {
    guard let header = pcmHeader(in: data) else { return nil }
    let sampleCount = header.sampleCount
    guard sampleCount > 0 else { return nil }
    // Резерв ограничиваем реально доступными байтами: объявленный dataSize
    // может быть огромным (префикс большого файла, size=2^32-1) — не
    // аллоцируем резерв под несуществующие сэмплы перед проверкой.
    let availableSamples = max(0, (data.count - header.dataOffset) / 2)

    var samples: [Int16] = []
    samples.reserveCapacity(min(sampleCount, availableSamples))
    for i in 0..<sampleCount {
      let offset = header.dataOffset + i * 2
      guard offset + 2 <= data.count else { break }
      let value = readUInt16LE(data, at: offset)
      samples.append(Int16(bitPattern: value))
    }
    guard samples.count == sampleCount else { return nil }
    return WAVInfo(sampleRate: header.sampleRate, channels: header.channels, samples: samples)
  }

  /// Проверяет RIFF/WAVE-префикс файла (canonical WAV).
  private static func isRIFFWAVEPrefix(_ data: Data) -> Bool {
    String(bytes: data[0..<4], encoding: .ascii) == "RIFF"
      && String(bytes: data[8..<12], encoding: .ascii) == "WAVE"
  }

  /// Поля fmt-чанка, значимые для декодирования (PCM 16-bit).
  private struct PCMFmtChunk {
    var channels: Int
    var sampleRate: Int
    var bitsPerSample: Int
  }

  /// Разбирает fmt-чанк (canonical PCM 16-bit). Возвращает nil, если чанк
  /// не соответствует требованиям: минимальный размер, audioFormat == 1,
  /// битность == 16.
  private static func readFmtChunk(
    _ data: Data,
    payloadStart: Int,
    size: Int
  ) -> PCMFmtChunk? {
    guard size >= 16 else { return nil }
    let audioFormat = Int(readUInt16LE(data, at: payloadStart))
    guard audioFormat == 1 else { return nil }  // PCM only
    let fmt = PCMFmtChunk(
      channels: Int(readUInt16LE(data, at: payloadStart + 2)),
      sampleRate: Int(readUInt32LE(data, at: payloadStart + 4)),
      bitsPerSample: Int(readUInt16LE(data, at: payloadStart + 14))
    )
    guard fmt.bitsPerSample == 16 else { return nil }
    return fmt
  }

  private static func readUInt16LE(_ bytes: Data, at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ bytes: Data, at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }
}
