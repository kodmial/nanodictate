// swiftlint:disable file_length

import Foundation

// MARK: - Ответственность: пакетная сегментация файла (без микрофонного пути)

// Разбиение PCM-сэмплов файла на чанки с оверлэпом. По умолчанию границы
// ВЫРАВНИВАЮТСЯ на паузы речи (cutAtPauses = true, рекомендация «Практики
// длинной речи»: резать по тишине ≥ 0.3 с, не по фиксированному таймеру —
// меньше галлюцинаций обрезанного слова на кромке чанка); для файлов без
// пауз/при cutAtPauses = false — фиксированная длина (maxSegment секунд).
// Чанк = последние overlap секунд ТЕЛА предыдущего чанка + тело текущего
// чанка. Тела чанков идут подряд без пропусков и перекрытий — файл покрыт
// полностью, каждый сэмпл транскрибируется ровно один раз как «тело», а
// оверлэп даёт контекст на границе. Детекция тишины — RMS-порог по PCM
// (без внешних onnx-моделей): window 0.085 с, порог nearSilenceThreshold
// (~0.00316, −50 dBFS), пауза ≥ pauseDuration (0.3 с по умолчанию).

// MARK: - Абстракция источника сэмплов (read-окна файла vs in-memory массив)

/// Источник PCM-сэмплов для пакетной нарезки. Поддерживает произвольные
/// read-окна — BatchBodySpec.materializes samples на demande, не загружая
/// весь файл в RAM. Array-реализация хранит сэмплы в памяти (run(samples:)),
/// файловая — читает через FileHandle (run(fileURL:)).
public protocol PCMBatchContent: AnyObject {
  var sampleRate: Int { get }
  var sampleCount: Int { get }
  /// Чтение сэмплов из диапазона (0-based, по моно-каналу).
  /// Диапазон за пределами файла обрезается до [0, sampleCount); при
  /// недоборе реальных данных (усечённый/конкурентно изменённый файл)
  /// бросает ошибку — молчаливый обрубок окна недопустим.
  func readSamples(_ range: Range<Int>) throws -> [Int16]
}

/// In-memory источник (массив сэмплов + sampleRate). Для тестов и legacy-пути.
public final class ArrayPCMBatchContent: PCMBatchContent {
  public let sampleRate: Int
  public let sampleCount: Int
  private let samples: [Int16]

  public init(samples: [Int16], sampleRate: Int) {
    self.samples = samples
    self.sampleRate = sampleRate
    sampleCount = samples.count
  }

  public func readSamples(_ range: Range<Int>) throws -> [Int16] {
    let low = max(0, range.lowerBound)
    let high = min(sampleCount, range.upperBound)
    guard low < high else { return [] }
    let clamped = low..<high
    return Array(samples[clamped])
  }
}

/// Файловый источник: PCM-сэмплы читаются прямо из WAV через FileHandle.
/// Заголовок парсится из префикса (WAVDecoder.pcmHeader), сэмплы читаются
/// по request (seek+read под NSLock), в RAM только окно одного чанка.
/// Thread-safe: seek+read атомарны под readLock (воркеры вызывают параллельно).
public final class WAVFilePCMBatchContent: PCMBatchContent {
  public enum WAVFileError: Error, Equatable {
    case fileNotFound
    case invalidWAV
    /// OS-ошибка чтения/позиционирования (битый дескриптор, недоступный
    /// файл) — с описанием первопричины, чтобы не сквашивать её в invalidWAV.
    case ioError(String)
  }

  /// Префикс файла, читаемый для парсинга заголовка (fmt+data чанки).
  /// 2 МБ покрывает типичные WAV (afconvert-продукты, LIST/fact, крупные
  /// метаданные) — data-чанк практически всегда начинается раньше. Для
  /// канонических PCM16 хватает и 44 байт; лимит нужен только для
  /// длинных нестандартных чанков перед data.
  private static let prefixLength = 2 * 1024 * 1024

  public let sampleRate: Int
  public let channels: Int
  public let sampleCount: Int
  private let handle: FileHandle
  private let readLock = NSLock()
  private let dataOffset: Int

  public init(wavURL: URL) throws {
    guard FileManager.default.fileExists(atPath: wavURL.path) else {
      throw WAVFileError.fileNotFound
    }
    let handle = try FileHandle(forReadingFrom: wavURL)
    do {
      let prefix = try handle.read(upToCount: Self.prefixLength) ?? Data()
      guard let header = WAVDecoder.pcmHeader(in: prefix) else {
        throw WAVFileError.invalidWAV
      }
      // readSamples читает 16-bit сэмплы плоским массивом — стерео WAV
      // дал бы перемеженные каналы двойной длины вместо моно-аудио.
      guard header.channels == 1 else {
        throw WAVFileError.invalidWAV
      }
      // readSamples обращается к произвольным окнам вплоть до
      // dataOffset+dataSize — весь объявленный payload обязан лежать в
      // файле. Усечённый WAV (pcmHeader видит только префикс, dataSize
      // мог бы быть огромным) дал бы пустые read-окна без ошибки — здесь
      // сверяем объявленный размер с фактической длиной и отсекаем.
      let fileLength = handle.seekToEndOfFile()
      guard fileLength >= UInt64(header.dataOffset) + UInt64(header.dataSize) else {
        throw WAVFileError.invalidWAV
      }
      self.handle = handle
      dataOffset = header.dataOffset
      sampleRate = header.sampleRate
      channels = header.channels
      sampleCount = header.sampleCount
    } catch {
      try? handle.close()
      if let wavError = error as? WAVFileError {
        throw wavError  // invalidWAV от гардов — уже осмысленная ошибка
      }
      // OS-ошибка read/seek (недоступный файл, битый дескриптор) —
      // не сквашиваем в invalidWAV, сохраняем первопричину.
      throw WAVFileError.ioError(error.localizedDescription)
    }
  }

  deinit {
    try? handle.close()
  }

  /// Seek+read окна сэмплов под блокировкой; поток data-чанка → Int16 LE.
  /// Фактически прочитанное сверяется с запрошенным: EOF до конца окна
  /// (файл короче объявленного dataSize) — throw, а не молчаливый обрубок.
  public func readSamples(_ range: Range<Int>) throws -> [Int16] {
    let low = max(0, range.lowerBound)
    let high = min(sampleCount, range.upperBound)
    guard low < high else { return [] }
    let clamped = low..<high
    readLock.lock()
    defer { readLock.unlock() }
    var out: [Int16] = []
    out.reserveCapacity(clamped.count)
    var remainingBytes = clamped.count * 2
    do {
      try handle.seek(toOffset: UInt64(dataOffset + clamped.lowerBound * 2))
      while remainingBytes > 0 {
        guard let data = try handle.read(upToCount: remainingBytes), !data.isEmpty else { break }
        var i = 0
        while i + 1 < data.count {
          let value = UInt16(data[i]) | (UInt16(data[i + 1]) << 8)
          out.append(Int16(bitPattern: value))
          i += 2
        }
        remainingBytes -= data.count
      }
    } catch {
      throw WAVFileError.ioError(error.localizedDescription)
    }
    guard out.count == clamped.count else {
      throw WAVFileError.invalidWAV  // недобор: файл короче объявленного dataSize
    }
    return out
  }
}

// MARK: - Spec тела чанка (без сэмплов): границы + read-окна

/// Метаданные одного чанка: bodyStart/bodyEnd в секундах, read-окна для тела
/// и оверлэпа. Сэмплы материализуются на demande через samples(from:).
/// Это позволяет хранить в RAM только ~N чанков (где N ≤ maxConcurrent).
public struct BatchBodySpec: Equatable {
  public let index: Int
  public let bodyStart: TimeInterval  // секунды от начала файла
  public let bodyEnd: TimeInterval
  /// Read-окно тела (в сэмплах, 0-based, моно).
  public let bodyRange: Range<Int>
  /// Read-окно оверлэпа (хвост тела предыдущего чанка); nil — первый чанк.
  public let overlapRange: Range<Int>?

  /// Материализация сэмплов: overlap + body (с учётом read-окон из source).
  /// Пробрасывает ошибки readSamples (недобор — усечённый файл).
  public func samples(from content: PCMBatchContent) throws -> [Int16] {
    var result: [Int16] = []
    if let overlap = overlapRange {
      try result.append(contentsOf: content.readSamples(overlap))
    }
    try result.append(contentsOf: content.readSamples(bodyRange))
    return result
  }

  public static func == (lhs: BatchBodySpec, rhs: BatchBodySpec) -> Bool {
    lhs.index == rhs.index
      && lhs.bodyStart == rhs.bodyStart && lhs.bodyEnd == rhs.bodyEnd
      && lhs.bodyRange == rhs.bodyRange && lhs.overlapRange == rhs.overlapRange
  }
}

/// Один чанк пакетного распознавания.
public struct BatchChunk: Equatable {
  /// Порядковый номер (0-based).
  public let index: Int
  /// Начало тела чанка от начала файла, секунды (без оверлэпа).
  public let bodyStart: TimeInterval
  /// Конец тела чанка от начала файла, секунды (без оверлэпа).
  public let bodyEnd: TimeInterval
  /// PCM-сэмплы: последние `overlap` секунд тела предыдущего чанка (или
  /// целиком предыдущее тело, если оно короче оверлэпа) + тело текущего.
  /// У первого чанка — только тело.
  public let samples: [Int16]

  public init(index: Int, bodyStart: TimeInterval, bodyEnd: TimeInterval, samples: [Int16]) {
    self.index = index
    self.bodyStart = bodyStart
    self.bodyEnd = bodyEnd
    self.samples = samples
  }
}

public enum BatchSegmenter {
  /// Нарезает Int16 PCM-сэмплы (16 кГц) на чанки фиксированной длины с
  /// оверлэпом. Гарантии:
  /// - тела чанков покрывают файл подряд без пропусков и перекрытий;
  /// - каждый чанк (кроме первого) начинает сэмплы с хвоста тела
  ///   предыдущего чанка длиной `overlap` секунд (контекст границы);
  /// - пустые входные сэмплы дают пустой результат.
  public static func segments(
    samples: [Int16],
    sampleRate: Int = 16000,
    maxSegment: TimeInterval = 30,
    overlap: TimeInterval = 2.5
  ) -> [BatchChunk] {
    guard !samples.isEmpty else { return [] }
    let bodySize = max(1, Int((maxSegment * Double(sampleRate)).rounded()))
    let overlapCount = max(0, min(Int((overlap * Double(sampleRate)).rounded()), samples.count))

    var result: [BatchChunk] = []
    var bodyStart = 0
    var prevBodyEnd: Int?
    var index = 0

    while bodyStart < samples.count {
      let bodyEnd = min(bodyStart + bodySize, samples.count)
      let body = Array(samples[bodyStart..<bodyEnd])

      var chunkSamples = body
      if let prevBodyEnd, overlapCount > 0 {
        let overlapFrom = max(0, prevBodyEnd - overlapCount)
        chunkSamples = Array(samples[overlapFrom..<prevBodyEnd]) + body
      }

      result.append(
        BatchChunk(
          index: index,
          bodyStart: TimeInterval(bodyStart) / Double(sampleRate),
          bodyEnd: TimeInterval(bodyEnd) / Double(sampleRate),
          samples: chunkSamples
        ))

      index += 1
      prevBodyEnd = bodyEnd
      bodyStart = bodyEnd
    }
    return result
  }

  // MARK: - Unified plan() — boundaries через PCMBatchContent (read-окна)

  /// Нарезка на чанки с read-окнами (для параллельного/файлового пути).
  /// Одинаковая математика с segments(samples:...) для фиксированного
  /// режима; в режиме cutAtPauses граница чанка сдвигается к ближайшей
  /// паузе в окне target±maxDrift (по RMS, window ≈ 0.085 с).
  ///
  /// - Parameters:
  ///   - content: источник сэмплов (Array или WAV-файл через FileHandle).
  ///   - maxSegment: целевая длина тела чанка (секунды).
  ///   - overlap: оверлэп (секунды); хвост тела предыдущего чанка.
  ///   - cutAtPauses: выравнивать границу чанка на паузу ≥ pauseDuration
  ///     в окне [target - drift, target + drift]. По умолчанию true
  ///     (рекомендация отчёта — резать по тишине, не по таймеру). При true
  ///     граница ≈ pause start (конец речи, меньше галлюцинаций на кромке).
  ///     При false — фиксированная длина (как segments(samples:...)).
  ///   - pauseDuration: минимальная длина паузы (секунды) для вырезания;
  ///     по умолчанию 0.3 с (граница тишины ≥ ~300 мс — не режет слово).
  ///   - maxDrift: максимальное отклонение границы от target (секунды).
  /// - Throws: ошибку readSamples при недоборе данных (усечённый файл).
  /// - Note: breaking change — cutAtPauses по умолчанию включён,
  ///   pauseDuration 0.3 с; для старого поведения вызвать
  ///   plan(cutAtPauses: false, pauseDuration: 1.0).
  public static func plan(
    content: PCMBatchContent,
    maxSegment: TimeInterval = 30,
    overlap: TimeInterval = 2.5,
    cutAtPauses: Bool = true,
    pauseDuration: TimeInterval = 0.3,
    maxDrift: TimeInterval = 5.0
  ) throws -> [BatchBodySpec] {
    let sampleRate = content.sampleRate
    let totalSamples = content.sampleCount
    guard totalSamples > 0 else { return [] }

    let bodySize = max(1, Int((maxSegment * Double(sampleRate)).rounded()))
    let overlapCount = max(0, min(Int((overlap * Double(sampleRate)).rounded()), totalSamples))
    let maxDriftSamples = Int((maxDrift * Double(sampleRate)).rounded())
    let minPauseSamples = Int((pauseDuration * Double(sampleRate)).rounded())
    let windowSize = max(
      1, Int((AudioSegmenter.defaultWindowDuration * Double(sampleRate)).rounded()))

    var result: [BatchBodySpec] = []
    var bodyStart = 0
    var prevBodyEnd: Int?
    var index = 0

    while bodyStart < totalSamples {
      var bodyEnd = min(bodyStart + bodySize, totalSamples)

      // Поиск паузы near boundary: only when cutAtPauses and
      // bodyEnd != totalSamples (не режем последний кусок).
      if cutAtPauses, bodyEnd != totalSamples {
        if let boundary = try pauseCut(
          content: content,
          target: bodyStart + bodySize,
          minBoundary: max(bodyStart + bodySize / 2, prevBodyEnd ?? bodyStart),
          maxDriftSamples: maxDriftSamples,
          minPauseSamples: minPauseSamples,
          windowSize: windowSize
        ), boundary > bodyStart {
          // Только продвигающий границу рез: boundary <= bodyStart дал бы
          // пустой spec (segment без содержимого).
          bodyEnd = boundary
        }
      }

      let overlapRange: Range<Int>? = prevBodyEnd.map {
        max(0, $0 - overlapCount)..<$0
      }

      result.append(
        BatchBodySpec(
          index: index,
          bodyStart: TimeInterval(bodyStart) / Double(sampleRate),
          bodyEnd: TimeInterval(bodyEnd) / Double(sampleRate),
          bodyRange: bodyStart..<bodyEnd,
          overlapRange: overlapRange
        ))

      index += 1
      prevBodyEnd = bodyEnd
      bodyStart = bodyEnd
    }
    return result
  }

  /// Поиск границы паузы (silence start) в окне around target.
  /// Возвращает boundary (индекс сэмпла, начало паузы) или nil, если
  /// подходящей паузы не найдено. Параметры — в сэмплах. Пробрасывает
  /// ошибки readSamples (недобор данных в усечённом файле).
  // swiftlint:disable:next function_parameter_count
  private static func pauseCut(
    content: PCMBatchContent,
    target: Int,
    minBoundary: Int,
    maxDriftSamples: Int,
    minPauseSamples: Int,
    windowSize: Int
  ) throws -> Int? {
    let low = max(minBoundary, target - maxDriftSamples)
    let high = min(content.sampleCount, target + maxDriftSamples)
    guard high - low >= minPauseSamples else { return nil }

    var best: (start: Int, dist: Int)?
    var cursor = low
    var runStart: Int?

    while cursor < high {
      let winEnd = min(cursor + windowSize, high)
      let window = try content.readSamples(cursor..<winEnd)
      let rms = AudioMetrics.rms(samples: window)
      let isSilent = rms < AudioMetrics.nearSilenceThreshold

      if isSilent, runStart == nil {
        runStart = cursor
      } else if !isSilent, let pauseStart = runStart {
        let len = cursor - pauseStart
        if len >= minPauseSamples {
          // Пауза найдена — boundary = pauseStart (начало паузы, конец речи).
          let start = max(pauseStart, minBoundary)
          recordBest(&best, start: start, target: target, minBoundary: minBoundary)
        }
        runStart = nil
      }
      cursor = winEnd
    }
    // Необработанный run на EOF.
    if let pauseStart = runStart, (high - pauseStart) >= minPauseSamples {
      let start = max(pauseStart, minBoundary)
      recordBest(&best, start: start, target: target, minBoundary: minBoundary)
    }
    return best?.start
  }

  /// Запись лучшей найденной границы: если начальная позиция ≥ minBoundary
  /// и её отклонение от target меньше текущего лучшего — заменяет лучшую.
  /// Вынесено из pauseCut, чтобы не дублировать сравнение на двух путях.
  private static func recordBest(
    _ best: inout (start: Int, dist: Int)?,
    start: Int,
    target: Int,
    minBoundary: Int
  ) {
    guard start >= minBoundary else { return }
    let dist = abs(start - target)
    if best.map({ dist < $0.dist }) ?? true {
      best = (start, dist)
    }
  }
}
