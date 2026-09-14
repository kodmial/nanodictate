import Foundation
import AVFoundation
@testable import DictationCore

/// Тесты драйва AVAudioConverter в AudioService: один входной буфер должен давать
/// ровно один выходной кусок `~target/input` от входа — без дублирования
/// (регрессия растянутой/«заикающейся» записи при ресемплинге 44.1/48 кГц → 16 кГц).
final class AudioCaptureTests: XCTestCase {

    // MARK: - Ресемплинг одного буфера

    @objc func testSingleBufferResampleNoDuplication() {
        let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false
        )!
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let converter = AVAudioConverter(from: inputFmt, to: outFmt)!

        // Вход: 4410 фреймов 44.1 кГц = 100 мс речи.
        let input = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: 4410)!
        input.frameLength = 4410
        // Постоянная амплитуда 16-бит: нет риска нулевой энергии.
        let samples = input.int16ChannelData![0]
        for i in 0..<4410 {
            samples[i] = Int16(6000)
        }

        let result = AudioService.convertOnce(
            input: input, inputFormat: inputFmt, converter: converter, targetFormat: outFmt
        )
        XCTAssertNotNil(result, "4410 фр. 44.1кГц → 16 кГц должен дать непустой выход")
        guard let result = result else { return }

        let out = result.converted
        XCTAssertTrue(out.frameLength > 0, "выход не должен быть пустым")

        // Ожидание: 4410 × 16000 / 44100 = 1600 фреймов — одна порция, без дублей.
        let expected = 1600
        let tolerance = Int(Double(expected) * 0.02) // допуск ±2%
        XCTAssertGreaterThanOrEqual(
            Int(out.frameLength), expected - tolerance,
            "frameLength \(out.frameLength) < \(expected - tolerance) — выход потерян"
        )
        XCTAssertLessThanOrEqual(
            Int(out.frameLength), expected + tolerance,
            "frameLength \(out.frameLength) > \(expected + tolerance) — аудио продублировано"
        )
        // Старый баг: frameCapacity = входу (4410) → выход 4410 вместо ~1600.
        XCTAssertFalse(Int(out.frameLength) == 4410, "выход не должен совпадать с входной длиной")

        // Статус — валидный данными-статус (не .error).
        XCTAssertTrue(
            result.status == .haveData
                || result.status == .inputRanDry
                || result.status == .endOfStream,
            "статус \(result.status.rawValue) не должен быть ошибкой"
        )
    }

    // MARK: - Переиспользование конвертера между буферами

    @objc func testConverterReuseMultipleBuffersNoLoss() {
        let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false
        )!
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
        )!
        // ОДИН конвертер на все чанки — как в process при живом tap.
        let converter = AVAudioConverter(from: inputFmt, to: outFmt)!

        // Три последовательных буфера по 100 мс: каждый должен дать ~1600 фр.
        // (ловит И дубли старого бага, И потерю чанков 2..N при endOfStream-защёлке).
        let amplitudes: [Int16] = [2000, 6000, 10000]
        var chunkLengths: [Int] = []
        var chunkMeans: [Float] = []

        for amp in amplitudes {
            let input = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: 4410)!
            input.frameLength = 4410
            let samples = input.int16ChannelData![0]
            for i in 0..<4410 {
                samples[i] = amp
            }

            let result = AudioService.convertOnce(
                input: input, inputFormat: inputFmt, converter: converter, targetFormat: outFmt
            )
            XCTAssertNotNil(result, "чанк с амплитудой \(amp) должен дать непустой выход")
            guard let result = result else { return }

            let out = result.converted
            XCTAssertTrue(
                out.frameLength > 0,
                "чанк \(amp): конвертер не должен терять данные после первого буфера"
            )
            let n = Int(out.frameLength)
            chunkLengths.append(n)

            // Энергия чанка: средняя амплитуда выходных сэмплов.
            let ch = out.int16ChannelData![0]
            var sum: Float = 0
            for i in 0..<n {
                sum += Float(abs(ch[i]))
            }
            chunkMeans.append(n > 0 ? sum / Float(n) : 0)
        }

        // Каждый вызов — ~1600 фреймов (допуск ±2%); старый баг дал бы 4410.
        for n in chunkLengths {
            XCTAssertGreaterThanOrEqual(n, 1568, "чанк \(n) < 1568 — данные потеряны")
            XCTAssertLessThanOrEqual(n, 1632, "чанк \(n) > 1632 — дублирование")
        }

        // Сумма трёх чанков ≈ 4800 ±2%.
        let total = chunkLengths.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 4704, "total \(total) < 4704 — часть данных после первого буфера потеряна")
        XCTAssertLessThanOrEqual(total, 4896, "total \(total) > 4896 — данные продублированы")

        // Амплитуды чанков РАЗНЫЕ (одинаковые = дублирование одного куска).
        XCTAssertTrue(
            chunkMeans[0] < chunkMeans[1] && chunkMeans[1] < chunkMeans[2],
            "средние амплитуды должны расти вслед за входными: \(chunkMeans)"
        )
    }
}