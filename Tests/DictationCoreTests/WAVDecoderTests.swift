import Foundation
@testable import DictationCore

// MARK: - Тесты WAVDecoder (разбор RIFF/PCM в Int16-сэмплы)

final class WAVDecoderTests: XCTestCase {

    // MARK: Ручной сборщик RIFF/WAV для нестандартных случаев

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// Собирает WAV-файл: fmt (PCM/битность/каналы/rate) + data + набор
    /// необязательных чанков перед data ("LIST"/"fact" и т.п.).
    /// - Parameters:
    ///   - extraChunks: чанки (id + payload), размещаемые между fmt и data.
    ///     Нечётный payload дополняется байтом паддинга (word-align, 2 байта).
    ///   - declaredDataSize: объявленный в заголовке data-чанка размер
    ///     payload (по умолчанию = реальный размер sampleBytes). Может быть
    ///     больше реального — эмулирует префикс большого файла, где в окне
    ///     есть только заголовок data, а payload лежит дальше.
    ///   - includeData: false — собрать WAV БЕЗ data-чанка (fmt и extra).
    private func makeWAV(
        sampleRate: Int = 16000,
        channels: Int = 1,
        bits: Int = 16,
        audioFormat: UInt16 = 1,
        samples: [Int16] = [0, 1, -1],
        extraChunks: [(id: String, payload: [UInt8])]? = nil,
        declaredDataSize: Int? = nil,
        includeData: Bool = true
    ) -> Data {
        var sampleBytes: [UInt8] = []
        for s in samples {
            let u = UInt16(bitPattern: s)
            if bits == 16 {
                sampleBytes.append(UInt8(u & 0xFF))
                sampleBytes.append(UInt8(u >> 8))
            }
        }
        let extra = extraChunks ?? []
        let extraBytes = extra.reduce(0) { $0 + 8 + $1.payload.count + ($1.payload.count % 2) }
        let declaredSize = declaredDataSize ?? sampleBytes.count

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        let riffSize = 4 + (8 + 16) + extraBytes + (includeData ? 8 + sampleBytes.count : 0)
        appendUInt32LE(UInt32(riffSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &data)
        appendUInt16LE(audioFormat, to: &data) // 1 = PCM
        appendUInt16LE(UInt16(channels), to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(sampleRate * channels * bits / 8), to: &data)
        appendUInt16LE(UInt16(channels * bits / 8), to: &data)
        appendUInt16LE(UInt16(bits), to: &data)

        // Незнакомые чанки (LIST, fact и т.п.) — должны пропускаться.
        for chunk in extra {
            data.append(contentsOf: Array(chunk.id.utf8))
            appendUInt32LE(UInt32(chunk.payload.count), to: &data)
            data.append(contentsOf: chunk.payload)
            if chunk.payload.count % 2 != 0 {
                data.append(0) // паддинг до чётной границы
            }
        }

        // data
        guard includeData else { return data }
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(UInt32(declaredSize), to: &data)
        data.append(contentsOf: sampleBytes)
        return data
    }

    /// Пишет WAV во временный файл на диске и возвращает его URL
    /// (удаляется тестом через removeItem). Параметры — как у makeWAV.
    private func makeWAVFile(
        sampleRate: Int = 16000,
        channels: Int = 1,
        samples: [Int16],
        extraChunks: [(id: String, payload: [UInt8])]? = nil,
        declaredDataSize: Int? = nil,
        includeData: Bool = true
    ) throws -> URL {
        let wav = makeWAV(
            sampleRate: sampleRate, channels: channels, samples: samples,
            extraChunks: extraChunks, declaredDataSize: declaredDataSize,
            includeData: includeData
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dct-wav-\(UUID().uuidString).wav")
        try wav.write(to: url)
        return url
    }

    // MARK: Круглые пути через WAVEncoder

    @objc func testRoundTripWithEncoder() {
        let samples: [Int16] = [-32768, -1, 0, 1, 32767, 12345, -5432]
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("декодер не разобрал WAV от WAVEncoder")
            return
        }
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.samples, samples)
    }

    // MARK: Отклонения

    @objc func testRejectsNotWAV() {
        XCTAssertNil(WAVDecoder.decodePCM16(Data("совсем не wav".utf8)))
    }

    @objc func testRejectsNonPCMFormat() {
        let wav = makeWAV(audioFormat: 3) // IEEE float
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "только PCM (audioFormat == 1)")
    }

    @objc func testRejectsNon16Bit() {
        let wav = makeWAV(bits: 8)
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "только 16-бит")
    }

    @objc func testRejectsTruncatedHeader() {
        var wav = makeWAV()
        wav = wav.prefix(20)
        XCTAssertNil(WAVDecoder.decodePCM16(wav))
    }

    @objc func testRejectsEmptyDataChunk() {
        let wav = makeWAV(samples: [])
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "data без сэмплов — nil")
    }

    // MARK: Нестандартные, но валидные файлы

    @objc func testSkipsUnknownChunks() {
        let wav = makeWAV(samples: [7, -7], extraChunks: [("LIST", Array("JUNKINFO".utf8))])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("LIST-чанк должен пропускаться")
            return
        }
        XCTAssertEqual(info.samples, [7, -7])
        XCTAssertEqual(info.sampleRate, 16000)
    }

    @objc func testMultiChannelSamplesInterleaved() {
        let wav = makeWAV(sampleRate: 8000, channels: 2, samples: [1, 2, 3, 4])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("мультиканальный PCM должен декодироваться")
            return
        }
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleRate, 8000)
        XCTAssertEqual(info.samples, [1, 2, 3, 4], "сэмплы по каналам подряд (interleaved)")
    }

    @objc func testNegativeSamplesPreserved() {
        let wav = makeWAV(samples: [-1234, 0, 1234, -32768, 32767])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("отрицательные сэмплы должны сохраняться")
            return
        }
        XCTAssertEqual(info.samples, [-1234, 0, 1234, -32768, 32767])
    }

    @objc func testHighSampleRateKept() {
        let wav = makeWAV(sampleRate: 48000, samples: [5])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("48 кГц — валидный WAV")
            return
        }
        XCTAssertEqual(info.sampleRate, 48000)
    }

    // MARK: Сэмплы из реального WAV-файла

    @objc func testDecodesEncodedFileBytes() {
        // Двухканальный файл, собраный вручную, разбирается целиком.
        let wav = makeWAV(sampleRate: 16000, channels: 1, samples: Array(0..<100).map { Int16($0 * 100) })
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("провал декодирования")
            return
        }
        XCTAssertEqual(info.samples.count, 100)
        XCTAssertEqual(info.samples.last, Int16(99 * 100))
    }

    // MARK: pcmHeader — парсинг заголовка без копирования сэмплов

    @objc func testPCMHeaderStandard16kHzMono() {
        let wav = makeWAV(sampleRate: 16000, channels: 1, samples: [1, 2, 3])
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("стандартный PCM16 WAV должен разбираться")
            return
        }
        XCTAssertEqual(header.sampleRate, 16000)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.bitsPerSample, 16)
        // fmt (12 + 8 + 16) + data-заголовок (8) → сэмплы с байта 44.
        XCTAssertEqual(header.dataOffset, 44)
        XCTAssertEqual(header.dataSize, 6)
        XCTAssertEqual(header.sampleCount, 3)
    }

    @objc func testPCMHeaderSkipsLISTAndFactBeforeData() {
        // Структура реального «Собес полный wav.wav»: fmt → LIST/INFO → data.
        let listPayload: [UInt8] = Array("INFOISFT\0\0".utf8) // 10 байт, чётный — без паддинга
        let factPayload: [UInt8] = [0x04, 0x00, 0x00, 0x00]   // fact: 1 блок
        let wav = makeWAV(
            samples: [5, 6, 7, 8],
            extraChunks: [("LIST", listPayload), ("fact", factPayload)]
        )
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("LIST/fact перед data должны пропускаться")
            return
        }
        XCTAssertEqual(header.sampleRate, 16000)
        XCTAssertEqual(header.channels, 1)
        XCTAssertEqual(header.dataSize, 8)
        XCTAssertEqual(header.sampleCount, 4)
        // data-чанк идёт после: RIFF(12) + fmt(24) + LIST(8+10) + fact(8+4) + data-заголовок(8).
        XCTAssertEqual(header.dataOffset, 12 + 24 + 18 + 12 + 8)
        // Полный декод через тот же заголовок даёт исходные сэмплы.
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("декод с LIST/fact не должен падать")
            return
        }
        XCTAssertEqual(info.samples, [5, 6, 7, 8])
    }

    @objc func testPCMHeaderDataPayloadBeyondWindow() {
        // Ключевой регрессионный тест: заголовок data-чанка виден в префиксе,
        // но его payload (весь звук) НЕ помещается в окно — как при чтении
        // префикса большого файла (WAVFilePCMBatchContent).
        // Объявляем data размером 160 МБ (как у реального «Собес полный wav.wav»),
        // но физически в буфере только 3 сэмпла + заголовок.
        let wav = makeWAV(samples: [1, 2, 3], declaredDataSize: 160_926_378)
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("pcmHeader должен принимать data с payload больше окна")
            return
        }
        XCTAssertEqual(header.dataOffset, 44)
        XCTAssertEqual(header.dataSize, 160_926_378)
        XCTAssertEqual(header.sampleRate, 16000)
        XCTAssertEqual(header.channels, 1)
    }

    @objc func testDecodePCM16HugeDeclaredDataSizeShortBuffer() {
        // Прямой регресс-тест фикса #3 (reserveCapacity ограничен реально
        // доступными сэмплами): заголовок data-чанка в окне, объявленный
        // dataSize = 2^32-1 (префикс большого файла), буфер короткий
        // (data.count < dataOffset + dataSize) → decodePCM16 обязан вернуть
        // nil, а не резервировать ~2^31 сэмплов (4 ГБ) под несуществующий
        // payload перед проверкой обрезки.
        let listPayload = [UInt8](repeating: 0x41, count: 26) // RIFF(12)+fmt(24)+LIST(8+26)=70 → data-offset 70+8=78
        let wav = makeWAV(
            samples: [1, 2, 3],
            extraChunks: [("LIST", listPayload)],
            declaredDataSize: 4_294_967_295 // 2^32 - 1
        )
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("заголовок с огромным dataSize в окне должен парситься")
            return
        }
        XCTAssertEqual(header.dataOffset, 78)
        XCTAssertEqual(header.dataSize, 4_294_967_295)
        guard wav.count < header.dataOffset + header.dataSize else {
            XCTFail("прекондиция: буфер должен быть короче объявленного payload")
            return
        }
        XCTAssertNil(WAVDecoder.decodePCM16(wav),
                     "короткий буфер при огромном declaredDataSize — nil без гигантского reserveCapacity")
    }

    @objc func testPCMHeaderDataChunkFarBeyondWindow() {
        // data-чанк начинается дальше 64 КБ от начала файла — парсинг идёт по
        // цепочке чанков (LIST-метаданные большого размера перед data).
        let bigPayload = [UInt8](repeating: 0x41, count: 120_000) // > 64 КБ
        let wav = makeWAV(samples: [9, 10], extraChunks: [("LIST", bigPayload)])
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("data за 64 КБ должен находиться по цепочке чанков")
            return
        }
        XCTAssertEqual(header.dataSize, 4)
        XCTAssertEqual(header.sampleCount, 2)
        // data-чанк после: RIFF(12) + fmt(24) + LIST(8 + 120000) + data-заголовок(8).
        XCTAssertEqual(header.dataOffset, 12 + 24 + 8 + bigPayload.count + 8)
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("декод с data за 64 КБ не должен падать")
            return
        }
        XCTAssertEqual(info.samples, [9, 10])
    }

    // MARK: Порядок чанков и паддинг (решения ревью)

    @objc func testPCMHeaderRejectsDataBeforeFmt() {
        // Нестандартный порядок: data раньше fmt. Документированное поведение
        // pcmHeader — fmt обязан идти ДО data, data раньше fmt → nil.
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(16, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        // data первым.
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(4, to: &data)
        data.append(contentsOf: [0x01, 0x00, 0x02, 0x00])

        // fmt после data.
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(16000, to: &data)
        appendUInt32LE(32000, to: &data)
        appendUInt16LE(2, to: &data)
        appendUInt16LE(16, to: &data)

        XCTAssertNil(WAVDecoder.pcmHeader(in: data), "fmt до data — обязательное требование")
        XCTAssertNil(WAVDecoder.decodePCM16(data))
    }

    @objc func testPCMHeaderOddSizedChunkWithPadding() {
        // LIST с нечётным payload (7 байт): после payload обязателен байт
        // паддинга до чётной границы — парсер двигается cursor += size % 2.
        let oddPayload: [UInt8] = Array("JUNKINF".utf8) // 7 байт
        let wav = makeWAV(samples: [42, -42], extraChunks: [("LIST", oddPayload)])
        guard let header = WAVDecoder.pcmHeader(in: wav) else {
            XCTFail("LIST с нечётным size и паддингом должен проходить")
            return
        }
        XCTAssertEqual(header.dataSize, 4)
        XCTAssertEqual(header.sampleCount, 2)
        // RIFF(12) + fmt(24) + LIST(8 + 7 + 1 паддинг) + data-заголовок(8).
        XCTAssertEqual(header.dataOffset, 12 + 24 + (8 + 7 + 1) + 8)
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("декод с нечётным LIST не должен падать")
            return
        }
        XCTAssertEqual(info.samples, [42, -42])
    }

    @objc func testPCMHeaderMultipleDataChunksFirstWins() {
        // Два data-чанка (нестандартный файл): учитывается ПЕРВЫЙ, остальные
        // игнорируются (первая data wins).
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        appendUInt32LE(24, to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt16LE(1, to: &data)
        appendUInt32LE(16000, to: &data)
        appendUInt32LE(32000, to: &data)
        appendUInt16LE(2, to: &data)
        appendUInt16LE(16, to: &data)

        // Первый data: 2 сэмпла.
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(4, to: &data)
        data.append(contentsOf: [0x01, 0x00, 0x02, 0x00])

        // Второй data: ещё 2 сэмпла — должен игнорироваться.
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(4, to: &data)
        data.append(contentsOf: [0x03, 0x00, 0x04, 0x00])

        guard let header = WAVDecoder.pcmHeader(in: data) else {
            XCTFail("первый data-чанк должен распознаваться")
            return
        }
        XCTAssertEqual(header.dataSize, 4, "первая data wins — второй чанк не учитывается")
        XCTAssertEqual(header.dataOffset, 44)
        guard let info = WAVDecoder.decodePCM16(data) else {
            XCTFail("декод с двумя data-чанками не должен падать")
            return
        }
        XCTAssertEqual(info.samples, [1, 2], "сэмплы берутся из ПЕРВОГО data-чанка")
    }

    // MARK: WAVFilePCMBatchContent — реальный файл на диске

    @objc func testWAVFileBatchContentReadsRealFileBeyond64KB() throws {
        // Реальный файл на диске: LIST (120 КБ) + fact перед data — data-чанк
        // начинается дальше 64 КБ, для парсинга заголовка нужен префикс 2 МБ.
        let samples = Array(0..<1000).map { Int16($0) }
        let bigPayload = [UInt8](repeating: 0x41, count: 120_000)
        let factPayload: [UInt8] = [0x04, 0x00, 0x00, 0x00]
        let url = try makeWAVFile(
            samples: samples,
            extraChunks: [("LIST", bigPayload), ("fact", factPayload)]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try WAVFilePCMBatchContent(wavURL: url)
        XCTAssertEqual(content.sampleRate, 16000)
        XCTAssertEqual(content.channels, 1)
        XCTAssertEqual(content.sampleCount, 1000)

        // Чтение окон из середины и хвоста совпадает с исходными сэмплами.
        let all = try content.readSamples(0..<1000)
        XCTAssertEqual(all, samples, "весь файл читается")
        let middle = try content.readSamples(100..<500)
        XCTAssertEqual(middle, Array(samples[100..<500]))
        let tail = try content.readSamples(990..<1010)
        XCTAssertEqual(tail, Array(samples[990..<1000]),
                       "окно за концом обрезается до sampleCount")
        // Диапазон целиком за файлом — пустой результат, без ошибки.
        let beyond = try content.readSamples(2000..<3000)
        XCTAssertTrue(beyond.isEmpty)
    }

    @objc func testWAVFileBatchContentRejectsMissingFile() throws {
        // Несуществующий URL: init бросает fileNotFound (а не invalidWAV) —
        // причина «файла нет», а не «файл битый». Регресс-тест throw-пути
        // init для отсутствующего файла.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dct-wav-missing-\(UUID().uuidString).wav")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "прекондиция: файла не существует")

        XCTAssertThrowsError(try WAVFilePCMBatchContent(wavURL: url)) { error in
            XCTAssertEqual(error as? WAVFilePCMBatchContent.WAVFileError,
                           WAVFilePCMBatchContent.WAVFileError.fileNotFound)
        }
    }

    @objc func testWAVFileBatchContentRejectsTruncatedFile() throws {
        // data-чанк объявляет 1 МБ, физически в файле только 3 сэмпла:
        // init обязан сверить dataOffset+dataSize с фактической длиной и
        // бросить invalidWAV (а не дать пустые read-окна без ошибки).
        let url = try makeWAVFile(samples: [1, 2, 3], declaredDataSize: 1_000_000)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WAVFilePCMBatchContent(wavURL: url)) { error in
            XCTAssertEqual(error as? WAVFilePCMBatchContent.WAVFileError,
                           WAVFilePCMBatchContent.WAVFileError.invalidWAV)
        }
    }

    @objc func testWAVFileBatchContentRejectsNoDataChunk() throws {
        // fmt без data-чанка: pcmHeader не находит data → invalidWAV.
        let url = try makeWAVFile(samples: [1, 2, 3], includeData: false)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WAVFilePCMBatchContent(wavURL: url)) { error in
            XCTAssertEqual(error as? WAVFilePCMBatchContent.WAVFileError,
                           WAVFilePCMBatchContent.WAVFileError.invalidWAV)
        }
    }

    @objc func testWAVFileBatchContentReadSamplesThrowsOnShortfall() throws {
        // Валидный файл открывается, затем усекается «под живую руку» (как при
        // конкурентной модификации) — readSamples обязан бросить ошибку при
        // недоборе, а не отдать молчаливый обрубок окна.
        let samples = Array(0..<100).map { Int16($0) }
        let url = try makeWAVFile(samples: samples)
        defer { try? FileManager.default.removeItem(at: url) }

        let content = try WAVFilePCMBatchContent(wavURL: url)
        XCTAssertEqual(content.sampleCount, 100)
        let head = try content.readSamples(0..<10)
        XCTAssertEqual(head, Array(samples[0..<10]),
                       "целый файл читается без ошибки")

        // Усекаем файл за спиной открытого источника (dataOffset=44 — удаляем
        // весь payload).
        let truncator = try FileHandle(forUpdating: url)
        try truncator.truncate(atOffset: 44)
        try truncator.close()

        XCTAssertThrowsError(try content.readSamples(0..<50)) { error in
            XCTAssertEqual(error as? WAVFilePCMBatchContent.WAVFileError,
                           WAVFilePCMBatchContent.WAVFileError.invalidWAV)
        }
    }
}