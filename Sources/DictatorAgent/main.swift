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

// MARK: - Agent

final class Agent: NSObject, HotkeyDelegate, AudioLevelDelegate {

    // Strong references на все сервисы — предотвращают их деаллокацию.
    private let sounds: SysSounds
    private let overlay: OverlayController
    private let audio: AudioService
    private let hotkeys: HotkeyService
    private let transcriber: Transcriber

    /// Уровень логирования из конфига: при "debug" в лог дополнительно пишется
    /// метрология (уровень RMS записи перед отправкой в STT).
    private let logLevel: String

    private var state: DictationState = .idle

    /// Сессионный токен фазы «обработка»: каждая новая отправка в STT
    /// инкрементирует его, и страж (watchdog) старого цикла видит расхождение
    /// токенов и не мешает новому циклу.
    private var processingSession = 0

    /// Старт записи «в полёте» (движок поднимается асинхронно на фоновой
    /// очереди AudioService): повторный Alt+Alt в это окно игнорируется, а не
    /// дублирует подъём движка.
    private var isStarting = false
    /// Сессионный токен старта: инкрементируется при каждом новом старте и при
    /// срабатывании сторожа подъёма — аннулирует устаревшие completion-колбэки.
    private var startSession = 0
    /// Сессионный токен запроса доступа к микрофону (TCC-диалог).
    private var micRequestSession = 0
    /// Системный диалог TCC уже висит — повторный Alt+Alt не открывает второй.
    private var micPermissionRequestInFlight = false
    /// Cooldown терминальных микрофонных ошибок (showMicrophoneError): пока
    /// доступ к микрофону не выдан / движок не поднялся, каждый Alt+Alt не
    /// должен снова играть Basso и мигать оверлеем — сообщение один раз в 3 с.
    private var micErrorCooldown = MicErrorCooldown(interval: 3.0)

    /// Жёсткий сторож подъёма аудиодвижка: `engine.start()` умеет блокироваться
    /// (смена устройства, инициализация после TCC-гранта). Старт идёт на фоновой
    /// очереди AudioService — главный поток не замирает, но без сторожа зависшая
    /// очередь оставила бы оверлей «Записываю…» навсегда. По таймауту — терминальная
    /// ошибка (оверлей гаснет, следующий Alt+Alt работает).
    private static let recordStartTimeout: TimeInterval = 10
    /// Сторож системного запроса доступа к микрофону: у фонового агента без
    /// бандла окно TCC может не отобразиться, и колбэк `requestAccess` не придёт —
    /// сторож даёт терминальную ошибку вместо вечного ожидания.
    private static let micRequestTimeout: TimeInterval = 10

    /// Retain-свойство для таймера автоподхвата права Accessibility
    /// (Timer.scheduledTimer с repeats:true не должен попадать под ARC/GC).
    private var accessibilityPollTimer: Timer?

    init(config: AppConfig) {
        self.logLevel = config.logLevel
        self.sounds = SysSounds(enabled: config.soundsEnabled)
        self.overlay = OverlayController(logLevel: config.logLevel)
        self.audio = AudioService(logLevel: config.logLevel)
        self.hotkeys = HotkeyService(
            doubleTapMaxInterval: config.doubleAltMaxInterval,
            logLevel: config.logLevel
        )
        self.transcriber = Transcriber(
            baseURL: config.baseURL,
            model: config.model,
            apiKey: config.apiKey,
            proxyKey: config.proxyKey,
            language: config.language,
            timeout: config.timeoutSeconds,
            logLevel: config.logLevel
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

    private var isDebug: Bool { logLevel.lowercased() == "debug" }

    private func handleAltDoubleTap() {
        if isDebug {
            Logger.log("Alt+Alt handled: state=\(String(describing: state))", level: "debug")
        }
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
    /// Три защиты от «просит разрешение → вылетает сообщение → зависает»:
    /// 1) повторный Alt+Alt, пока системный диалог TCC уже висит, не открывает
    ///    второй запрос (micPermissionRequestInFlight);
    /// 2) сторож micRequestTimeout: если колбэк requestAccess не пришёл (окно
    ///    у фонового агента без бандла могло не отобразиться) — терминальная
    ///    ошибка в оверлее вместо вечного ожидания; следующий Alt+Alt снова
    ///    попробует запросить доступ;
    /// 3) ветки .denied/.restricted дают понятное сообщение и НЕ трогают движок.
    private func requestMicrophoneAndStart() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        // Каждый запрос доступа к микрофону фиксируется в логе: сам факт проверки,
        // текущий статус TCC и результат системного диалога (granted/denied).
        Logger.log("mic permission check: \(MicrophoneAuth.statusText(status))", level: "info")
        switch status {
        case .authorized:
            startRecording()
        case .denied, .restricted:
            showMicrophoneError("Разрешите доступ к микрофону: System Settings → Конфиденциальность")
        case .notDetermined:
            guard !micPermissionRequestInFlight else {
                Logger.log("mic permission request already in flight — ignoring Alt+Alt", level: "info")
                return
            }
            micPermissionRequestInFlight = true
            micRequestSession += 1
            let session = micRequestSession
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.micRequestTimeout) { [weak self] in
                guard let self = self, self.micRequestSession == session else { return }
                Logger.log("mic permission request timed out after \(Int(Self.micRequestTimeout)) s", level: "error")
                self.micPermissionRequestInFlight = false
                self.showMicrophoneError("Запрос доступа к микрофону не обработан: System Settings → Конфиденциальность")
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.micRequestSession == session else { return }
                    self.micPermissionRequestInFlight = false
                    Logger.log("mic permission request result: \(granted ? "granted" : "denied")", level: "info")
                    granted ? self.startRecording()
                        : self.showMicrophoneError("Разрешите доступ к микрофону: System Settings → Конфиденциальность")
                }
            }
        @unknown default:
            showMicrophoneError("Разрешите доступ к микрофону: System Settings → Конфиденциальность")
        }
    }

    /// Логика старта записи: двигает агента в состояние .recording.
    /// Панель показывается здесь и держится ВЕСЬ цикл записи/распознавания;
    /// hide() вызывается только из терминальных точек (стоп/ошибка/вставка).
    /// Подъём движка асинхронный (AudioService.start(completion:) на фоновой
    /// очереди, completion на главном) + сторож recordStartTimeout: зависший
    /// движок даёт терминальную ошибку, а не вечно висящий оверлей.
    private func startRecording() {
        guard !isStarting else {
            Logger.log("record start ignored: already starting", level: "info")
            return
        }
        sounds.playStart()
        overlay.show()
        // Фаза «запись»: микрофон + таймер, время старта фиксируется здесь.
        overlay.setRecordingPhase()
        overlay.setStatus("Записываю…")
        Logger.log("record start")

        isStarting = true
        startSession += 1
        let session = startSession

        // Сторож подъёма движка: если за recordStartTimeout движок не стартовал
        // — терминальная ошибка (оверлей гаснет, следующий Alt+Alt работает).
        // startSession инкрементируется здесь же: отложенный completion старта
        // (если движок всё же поднялся позже) увидит расхождение токенов и
        // снимет движок через audio.cancel() — «глухой» записи не остаётся.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordStartTimeout) { [weak self] in
            guard let self = self, self.startSession == session, self.isStarting else { return }
            Logger.log("record start timed out after \(Int(Self.recordStartTimeout)) s", level: "error")
            self.startSession += 1
            self.isStarting = false
            self.audio.cancel()
            self.showMicrophoneError("Микрофон не отвечает")
        }

        audio.start { [weak self] result in
            guard let self = self else { return }
            guard self.startSession == session else {
                // Старт завершился позже сторожа (или начался новый цикл).
                // Если движок успели поднять — не оставляем запись висеть.
                if case .success = result {
                    self.audio.cancel()
                }
                return
            }
            self.isStarting = false
            switch result {
            case .success:
                self.state = .recording
                if self.isDebug {
                    Logger.log("record started: state = .recording", level: "debug")
                }
            case .failure(let error):
                Logger.log("microphone unavailable: \(error.localizedDescription)", level: "error")
                self.showMicrophoneError("Не удалось включить микрофон")
            }
        }
    }

    /// Терминальная ошибка микрофона: понятное сообщение в оверлее + звук
    /// ошибки (Basso). Одна точка hide — оверлей гаснет, state уже .idle,
    /// следующий Alt+Alt начинает новый цикл.
    private func showMicrophoneError(_ message: String) {
        // Cooldown: повторный Alt+Alt в сломанном состоянии (denied / движок
        // молчит) не должен заново играть звук ошибки и перерисовывать оверлей
        // — иначе при каждом нажатии слышен Basso и мигает панель. Cooldown
        // подавляет ТОЛЬКО звук и сообщение; hide ниже — всегда: панель,
        // показанная неудавшимся startRecording, не зависает со статусом
        // «Записываю…» до следующего Alt+Alt.
        let showFeedback = micErrorCooldown.allow(at: CFAbsoluteTimeGetCurrent())
        if showFeedback {
            overlay.setStatus(message)
            sounds.playError()
        } else if isDebug {
            Logger.log("mic error suppressed (cooldown active)", level: "debug")
        }
        hideAfter(2.0, reason: "mic failed")
    }

    private func sendRecording() {
        let samples = audio.stop()
        if isDebug {
            Logger.log("record stopped by user: \(samples.count) samples collected", level: "debug")
        }
        processSamples(samples)
    }

    /// Обычный путь финализации записи: сэмплы → WAV → транскрибация.
    /// Вызывается и по стопу пользователем, и после принудительной остановки
    /// по лимиту длительности (см. `onRecordingLimitReached`).
    private func processSamples(_ samples: [Int16]) {
        state = .transcribing
        // Фаза «обработка»: вместо иконки — анимация точек, пока идёт STT.
        overlay.setProcessingPhase()
        overlay.setStatus("Распознаю…")
        sounds.playEnd()
        // Длительность по фактически собранным сэмплам (16 кГц моно) —
        // видно, в каких единицах уходит аудио в STT.
        let duration = Double(samples.count) / 16000.0
        Logger.log(String(format: "transcribe submit (\(samples.count) samples, %.2f s)", duration), level: "info")

        // Что именно уходит в LLM: длительность + уровень RMS + флаг «около-тишины».
        // Метрология — только при log_level == "debug" (не спамить).
        if logLevel.lowercased() == "debug" {
            let rms = AudioMetrics.rms(samples: samples)
            let nearSilence = AudioMetrics.isNearSilence(avgRMS: rms)
            Logger.log(String(
                format: "STT input: duration=%.2f s, rms=%.4f (%.1f dBFS), nearSilence=%@",
                duration, Double(rms), Double(AudioMetrics.dbfs(rms)),
                nearSilence ? "true" : "false"
            ), level: "debug")
        }

        // Страж фазы «обработка»: анимация точек не может жить дольше жёсткого
        // таймаута запроса + небольшого запаса (processingMaxDuration). Если STT
        // за это время не завершился (сеть зависла, транспорт молчит) — цикл
        // завершаем сами, с сообщением «Таймаут STT». Сессионный токен не даёт
        // стражу старого цикла оборвать новый (пользователь уже начал новую
        // диктовку); проверка state == .transcribing делает страж no-op после
        // любого терминального события.
        processingSession += 1
        let session = processingSession
        DispatchQueue.main.asyncAfter(deadline: .now() + OverlayController.processingMaxDuration) { [weak self] in
            guard let self = self,
                  self.processingSession == session,
                  self.state == .transcribing else { return }
            self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
        }

        Task { [weak self] in
            guard let self = self else { return }

            // Тот же страж, что у watchdog-а выше: сессия «обработки»,
            // зафиксированная в момент отправки. Если к моменту завершения
            // Task сессия сменилась (новая диктовка) или цикл уже завершён
            // терминальным событием (watchdog «Таймаут STT» поставил state в
            // .idle) — терминальные вызовы становятся no-op, повторный
            // failTranscription/completeInsertion невозможен.
            let wav = WAVEncoder.encode(samples: samples)

            do {
                let result = try await self.transcriber.transcribe(wav: wav)
                let text = TextRefinement.finalize(result.text)

                DispatchQueue.main.async {
                    guard self.processingSession == session,
                          self.state == .transcribing else { return }
                    self.completeInsertion(text)
                }
            } catch {
                let networkText = OverlayErrorText.text(for: error)
                let message = networkText ?? Self.message(for: error)
                DispatchQueue.main.async {
                    guard self.processingSession == session,
                          self.state == .transcribing else { return }
                    self.failTranscription(message, isNetworkFailure: networkText != nil)
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
        overlay.resetPhase()
        overlay.setStatus("Завершаю…")
        hideAfter(0.8, reason: "insert done")
        state = .idle
        Logger.log("transcription inserted (\(text.count) chars)")
    }

    /// Терминальная точка цикла при ошибке STT (сеть, HTTP, таймаут).
    /// `isNetworkFailure == true` (нет интернета / таймаут STT) — дополнительно
    /// играем системный звук ошибки (Basso), чтобы пользователь понял сбой
    /// даже не глядя на оверлей.
    private func failTranscription(_ message: String, isNetworkFailure: Bool) {
        if isNetworkFailure {
            sounds.playError()
        }
        overlay.resetPhase()
        overlay.setStatus("Ошибка: \(message)")
        hideAfter(2.0, reason: "transcription failed")
        state = .idle
        Logger.log("transcription failed: \(message)", level: "error")
    }

    private func handleCancel() {
        guard state == .recording else { return }
        audio.cancel()
        overlay.resetPhase()
        overlay.setStatus("Отменено")
        sounds.playCancel()
        hideAfter(0.8, reason: "cancelled")
        state = .idle
        Logger.log("record cancelled")
    }

    // MARK: - Helpers

    /// Единственная точка вызова hide() — терминальные события цикла
    /// (mic denied, insert done, transcription failed, cancelled; лимит идёт
    /// тем же путём через processSamples). Задержка оставляет на экране
    /// финальный статус («Завершаю…»/«Отменено»). Решение о скрытии — чистая
    /// логика OverlayLifecycle в DictationCore: панель НЕ прячется, если
    /// к моменту срабатывания запись уже начата заново (state != .idle) —
    /// оверлей остаётся виден весь новый цикл.
    private func hideAfter(_ seconds: TimeInterval, reason: String) {
        if isDebug {
            Logger.log("overlay hide scheduled after \(seconds) s, reason=\(reason)", level: "debug")
        }
        OverlayLifecycle.scheduleHide(
            after: seconds,
            stateProvider: { [weak self] in self?.state ?? .idle }
        ) { [weak self] in
            self?.overlay.hide(reason: reason)
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