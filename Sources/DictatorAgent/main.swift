//
//  main.swift
//  DictatorAgent
//
//  Оркестратор фонового агента диктовки AltDictation.
//  Статическая машина состояний: idle → recording → transcribing → idle.
//  Swift 5.7, macOS 12, Intel. Только AppKit/Foundation/AVFoundation через DictationCore.
//

import AVFoundation
import AppKit
import ApplicationServices
import DictationCore

// MARK: - Состояния

enum DictationState {
    case idle
    case recording
    case transcribing
}

// MARK: - Agent

final class Agent: NSObject, HotkeyDelegate, AudioLevelDelegate {

    // Strong references на все сервисы — предотвращают их деаллокацию.
    private let sounds: SysSounds
    private let overlay: OverlayController
    private let audio: AudioService
    private let hotkeys: HotkeyService
    private let transcriber: Transcriber

    private var state: DictationState = .idle

    /// Retain-свойство для таймера автоподхвата права Accessibility
    /// (Timer.scheduledTimer с repeats:true не должен попадать под ARC/GC).
    private var accessibilityPollTimer: Timer?

    init(config: AppConfig) {
        self.sounds = SysSounds(enabled: config.soundsEnabled)
        self.overlay = OverlayController()
        self.audio = AudioService()
        self.hotkeys = HotkeyService(doubleTapMaxInterval: config.doubleAltMaxInterval)
        self.transcriber = Transcriber(
            baseURL: config.baseURL,
            model: config.model,
            apiKey: config.apiKey,
            proxyKey: config.proxyKey,
            timeout: config.timeoutSeconds
        )
        super.init()

        self.audio.levelDelegate = self
        self.hotkeys.delegate = self

        // Принудительная остановка по жёсткому лимиту (60 с) идёт тем же путём,
        // что и обычный стоп: сэмплы → WAV → транскрибация.
        self.audio.onRecordingLimitReached = { [weak self] samples in
            DispatchQueue.main.async {
                self?.handleRecordingLimitReached(samples: samples)
            }
        }
    }

    func start() throws {
        try hotkeys.start()
    }

    // MARK: - Accessibility (право «Доступность»)

    /// Запускает hotkey, если право Accessibility уже выдано; иначе сам открывает
    /// системную панель «Приватность и безопасность → Доступность» и каждые 2
    /// секунды опрашивает AXIsProcessTrusted(), пока пользователь не включит
    /// право — затем стартует hotkey и останавливает опрос.
    func startWithAccessibilityRequest() throws {
        if AXIsProcessTrusted() {
            try start()
            Logger.log("Hotkey service started", level: "info")
            return
        }

        // Панель открывается так же, как это делают Karabiner и подобные приложения.
        // Статическая строка-литерал гарантированно валидна на macOS 12+.
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        )
        Logger.log("Необходимо разрешить доступность для клавиатуры — системная панель открыта", level: "info")

        // Автоподхват права: опрос каждые 2 секунды на главном потоке.
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            if self.accessibilityPollTimer === timer {
                self.accessibilityPollTimer = nil
            }
            do {
                try self.start()
                Logger.log("Hotkey service started", level: "info")
            } catch {
                Logger.log("hotkey service failed to start: \(error.localizedDescription)", level: "error")
            }
        }
        RunLoop.main.add(accessibilityPollTimer!, forMode: .common)
    }

    // MARK: - HotkeyDelegate

    func altDoubleTapped() {
        DispatchQueue.main.async {
            self.handleAltDoubleTap()
        }
    }

    func cancelKeyPressed() {
        DispatchQueue.main.async {
            self.handleCancel()
        }
    }

    // MARK: - AudioLevelDelegate

    func audioLevelChanged(rms: Float) {
        // Колбэк installTap выполняется на аудио-потоке — переходим на main,
        // т.к. overlay.updateLevel трогает SwiftUI @Published.
        DispatchQueue.main.async {
            self.overlay.updateLevel(rms)
        }
    }

    // MARK: - Handlers

    private func handleAltDoubleTap() {
        switch state {
        case .idle:
            requestMicrophoneAndStart()
        case .recording:
            sendRecording()
        case .transcribing:
            // Заняты отправкой — игнорируем.
            break
        }
    }

    // MARK: - Запись

    /// Pre-flight: проверка доступа к микрофону до запуска движка.
    /// Не запрашиваем доступ принудительно из-под launchd (окно запроса может
    /// не отобразиться): только проверяем статус, а для .notDetermined пробуем
    /// запросить — и при granted начинаем запись.
    private func requestMicrophoneAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            startRecording()
        case .denied, .restricted:
            showMicrophoneError()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    granted ? self.startRecording() : self.showMicrophoneError()
                }
            }
        @unknown default:
            showMicrophoneError()
        }
    }

    /// Логика старта записи: двигает агента в состояние .recording.
    /// Панель показывается здесь и держится ВЕСЬ цикл записи/распознавания;
    /// hide() вызывается только из терминальных точек (стоп/ошибка/вставка).
    private func startRecording() {
        sounds.playStart()
        overlay.show()
        overlay.setStatus("Записываю…")
        Logger.log("record start")

        do {
            try audio.start()
            state = .recording
        } catch {
            showMicrophoneError()
            Logger.log("microphone unavailable: \(error.localizedDescription)", level: "error")
        }
    }

    private func showMicrophoneError() {
        overlay.setStatus("Нет доступа к микрофону (Настройки → Конфиденциальность)")
        sounds.playCancel()
        hideAfter(2.0, reason: "mic denied")
    }

    private func sendRecording() {
        let samples = audio.stop()
        processSamples(samples)
    }

    /// Обычный путь финализации записи: сэмплы → WAV → транскрибация.
    /// Вызывается и по стопу пользователем, и после принудительной остановки
    /// по лимиту длительности (см. `onRecordingLimitReached`).
    private func processSamples(_ samples: [Int16]) {
        state = .transcribing
        overlay.setStatus("Распознаю…")
        sounds.playEnd()
        Logger.log("transcribe submit (\(samples.count) samples)")

        Task { [weak self] in
            guard let self = self else { return }

            let wav = WAVEncoder.encode(samples: samples)

            do {
                let result = try await self.transcriber.transcribe(wav: wav)
                let text = TextRefinement.finalize(result.text)

                DispatchQueue.main.async {
                    self.completeInsertion(text)
                }
            } catch {
                let message = Self.message(for: error)
                DispatchQueue.main.async {
                    self.failTranscription(message)
                }
            }
        }
    }

    /// Запись остановлена по жёсткому лимиту (60 с / 960 000 сэмплов) —
    /// финализируем собранные сэмплы стандартным путём.
    private func handleRecordingLimitReached(samples: [Int16]) {
        guard state == .recording else { return }
        Logger.log("record limit reached (\(samples.count) samples)", level: "info")
        processSamples(samples)
    }

    private func completeInsertion(_ text: String) {
        Inserter.insert(text: text)
        overlay.setStatus("Завершаю…")
        hideAfter(0.8, reason: "insert done")
        state = .idle
        Logger.log("transcription inserted (\(text.count) chars)")
    }

    private func failTranscription(_ message: String) {
        overlay.setStatus("Ошибка: \(message)")
        hideAfter(2.0, reason: "transcription failed")
        state = .idle
        Logger.log("transcription failed: \(message)", level: "error")
    }

    private func handleCancel() {
        guard state == .recording else { return }
        audio.cancel()
        overlay.setStatus("Отменено")
        sounds.playCancel()
        hideAfter(0.8, reason: "cancelled")
        state = .idle
        Logger.log("record cancelled")
    }

    // MARK: - Helpers

    /// Единственная точка вызова hide() — терминальные события цикла.
    /// Задержка оставляет на экране финальный статус («Завершаю…»/«Отменено»).
    /// Панель НЕ прячется, если к моменту срабатывания запись уже начата заново
    /// (state != .idle) — оверлей остаётся виден весь новый цикл.
    private func hideAfter(_ seconds: TimeInterval, reason: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.state == .idle else { return }
            self.overlay.hide(reason: reason)
        }
    }

    private static func message(for error: Error) -> String {
        guard let transcribeError = error as? TranscribeError else {
            return error.localizedDescription
        }
        switch transcribeError {
        case .network(let message):
            return message
        case .http(let code, let body):
            return "HTTP \(code): \(body)"
        case .invalidResponse(let message):
            return message
        }
    }
}

// MARK: - Main

let config: AppConfig
do {
    config = try AppConfig.load(from: nil)
} catch {
    Logger.log("config load failed: \(error.localizedDescription)", level: "error")
    config = AppConfig.defaults
}

let app = NSApplication.shared
let agent = Agent(config: config)

do {
    // Проверяет AXIsProcessTrusted(); если права нет — сам открывает системную
    // панель «Доступность» и опрашивает раз в 2 сек до выдачи права (автоподхват).
    try agent.startWithAccessibilityRequest()
} catch {
    Logger.log("hotkey service failed to start: \(error.localizedDescription)", level: "error")
    let alert = NSAlert()
    alert.messageText = "Не удалось запустить агент диктовки"
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}

// Фоновый агент: без иконки в Dock и без меню-бара приложения.
NSApp.setActivationPolicy(.accessory)

app.run()