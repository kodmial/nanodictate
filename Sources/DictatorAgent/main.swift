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

    /// Последний WAV в памяти + повторное распознавание другим провайдером.
    /// Serves и автоfailover (см. `transcribeAutomatically`), и ручной retry
    /// из `dictatorctl retry <provider>` (через DistributedNotificationCenter).
    private let retryProvider: RetryProvider

    /// UX-настройки из конфига (прод-дефолты: метод cgevent, failover/review выкл).
    private let insertMethod: InsertMethod
    private let autoFailover: Bool
    private let reviewBeforeInsert: Bool

    /// Провайдеры в порядке failover (без активного): кандидаты на автоповтор.
    private let failoverCandidates: [AppConfig.Provider]
    /// Все провайдеры по id — для ручного retry через IPC.
    private let providersByID: [String: AppConfig.Provider]
    /// Имя активного провайдера (nil — legacy-конфиг без секций).
    private let activeProviderID: String?

    // MARK: Маршрутизация STT по ролям ([routing])

    /// id провайдера сегментов пошаговой диктовки (роль `segment` из
    /// `[routing]`); nil — роль не задана/фолбэк на активного. Решается в init
    /// ТОЛЬКО из конфига (резолверы не бросают), активное участие роли —
    /// в `roleTranscriber(_:)`.
    private let segmentRoleProviderID: String?
    /// id провайдера финального прохода по всей записи (роль `final` из
    /// `[routing]`); nil — роль не задана/фолбэк на активного.
    private let finalRoleProviderID: String?
    /// Единый построитель Transcriber из секции провайдера И ОБЩИХ настроек
    /// конфига (language/timeout/log_level/корневой proxyKeyHeader): через него
    /// идут активный путь, failover/retry и роли маршрутизации — повторы ведут
    /// себя как основной путь (тот же язык, таймаут и уровень лога).
    private let makeTranscriber: (AppConfig.Provider) -> Transcriber

    /// РАЗРЕШЁННЫЙ конфиг сессии — единый источник истины для реального
    /// запросного пути: из него в init собран Transcriber и cookie-relay-слой
    /// (baseURL/model/apiKey/transport), из него же на старте сессии
    /// вычисляется метка оверлея «через что идёт распознавание»
    /// (RecognitionLabel.forSession). Конфиг в момент показа оверлея не
    /// перечитывается — ярлык жёстко связан с провайдером распознавателя.
    private let resolvedConfig: AppConfig

    /// Наблюдатель DistributedNotificationCenter для ручного retry из CLI.
    private var retryObserver: NSObjectProtocol?

    /// Уровень логирования из конфига: при "debug" в лог дополнительно пишется
    /// метрология (уровень RMS записи перед отправкой в STT).
    private let logLevel: String

    /// Пошаговая диктовка (флаг `chunked = true` в конфиге): сегменты →
    /// инкрементальная вставка → финальный проход по всему WAV. OFF — ровно
    /// текущее поведение (один запрос).
    private let chunked: Bool

    // MARK: Live-диктовка (chunked = true)

    /// Серийный исполнитель живого цикла: уттеренсы распознаются СТРОГО по
    /// очереди — «хвост» останова встаёт перед финальным проходом, а каждый
    /// следующий сегмент получает prompt с текстом всех предыдущих. submit не
    /// блокирует вызывающего (main), каждый блок серийной очереди дожидается
    /// своего Task (паттерн ChunkedPipelineTests.testInsertAndPhaseAreSynchronous).
    private let liveExecutor = SerialAsyncExecutor()
    /// Токен живого цикла: новый старт записи / Esc аннулируют обработку
    /// сегментов старого цикла (страж вставки раньше времени). Читается и
    /// пишется на main; каждый цикл создаёт колбэк с захватом своего токена.
    private var liveSession = 0
    /// Накопление живого цикла (сегменты, prompt, флаги). Пишется ТОЛЬКО на
    /// liveExecutor (серийно); создаётся на main при каждом старте записи.
    private var liveRunState: LiveRunState?

    /// Накопление одного живого цикла диктовки. Поля инкрементально растут на
    /// liveExecutor; main читает их только для стражей (сессионные токены).
    private final class LiveRunState {
        let session: Int
        /// Сколько сегментов распознано и поставлено в очередь на вставку.
        var segmentCount = 0
        /// Текст, уже заявленный на вставку (с разделительными пробелами) —
        /// база для финального word-diff и prompt-аккумуляции.
        var insertedText = ""
        /// Части предыдущих сегментов для prompt следующего (чистый текст,
        /// без ведущих пробелов).
        var promptParts: [String] = []
        /// «Хвост» (незакрытый уттеренс при останове) доставлен: при одном
        /// сегменте он покрывает запись до конца — финальный проход не нужен.
        var tailDelivered = false
        /// Хотя бы один сегмент не распознался — финальный проход обязателен
        /// (он «докрутит» пропущенную фразу по всему WAV).
        var anySegmentFailed = false
        /// Текст последнего сбоя сегмента: при ПОЛНОМ сбое всех сегментов
        /// (segmentCount == 0) финал показывает явное сообщение об ошибке STT,
        /// а не сбивающий с толку «Пустой результат» (ревью #112).
        var lastErrorText: String?

        init(session: Int) {
            self.session = session
        }
    }

    /// Серийный исполнитель async-задач: каждая задача выполняется строго после
    /// предыдущей (пока та не завершилась), submit не блокирует вызывающего.
    /// Глубинная причина серийности: порядок вставок и доставка «хвоста» перед
    /// финальным проходом — DIFF финализации считает текст уже-вставленных
    /// сегментов, значит они обязаны быть обработаны раньше.
    private final class SerialAsyncExecutor {
        private let queue = DispatchQueue(label: "dictation.live.serial", qos: .userInitiated)

        func submit(_ body: @escaping () async -> Void) {
            queue.async {
                let sema = DispatchSemaphore(value: 0)
                Task {
                    await body()
                    sema.signal()
                }
                sema.wait()
            }
        }
    }

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

    // MARK: UX quick wins

    /// Токен отмены фазы «Распознаю…»: Esc во время STT ставит его, и результат
    /// вернувшегося запроса игнорируется (текст не вставляется). Сбрасывается
    /// при каждом новом цикле (processSamples).
    private var cancelRecognition = false

    /// Состояние undo: последняя УСПЕШНАЯ вставка (текст + момент времени).
    /// Двойной Alt в пределах undoMaxInterval после вставки стирает её.
    private var lastInsertedText: String?
    private var lastInsertedAt: TimeInterval?

    /// Окно undo и звук отката — из конфига (undo_max_interval /
    /// undo_sound_enabled). Значения копируются в init, чтобы не менять
    /// дата-класс конфига в процессе работы.
    private let undoMaxInterval: TimeInterval
    private let undoSoundEnabled: Bool

    /// Cooldown звука «пустой результат»: повторный Alt+Alt в тишине (<2 слов
    /// распознавания) не спамит Funk каждое нажатие. Отдельный от
    /// micErrorCooldown: «пустая диктовка» ≠ «ошибка микрофона».
    private var emptyResultCooldown = MicErrorCooldown(interval: 3.0)

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
        // Тот же resolved-конфиг, из которого ниже собран Transcriber, —
        // источник истины метки оверлея (RecognitionLabel.forSession).
        self.resolvedConfig = config
        self.undoMaxInterval = config.undoMaxInterval
        self.undoSoundEnabled = config.undoSoundEnabled
        self.chunked = config.chunked
        self.sounds = SysSounds(enabled: config.soundsEnabled)
        self.overlay = OverlayController(logLevel: config.logLevel)
        self.audio = AudioService(
            logLevel: config.logLevel,
            // Пломбинг автоостановки по тишине из окружения (сама фича — в
            // DictationCore/AudioService): пустое окружение → `.defaults`,
            // ровно по задаче (включено, ~3 c, −50 dBFS). Спасательный люк —
            // DICTATION_AUTOSTOP_DISABLED / _DURATION / _RMS, см. AutoStopConfig.
            autoStopConfig: AutoStopConfig.fromEnvironment()
        )
        self.hotkeys = HotkeyService(
            doubleTapMaxInterval: config.doubleAltMaxInterval,
            logLevel: config.logLevel
        )
        // Cookie-relay-слой включается только при transport = "cookie-relay"
        // (legacy-алиасы старого конфига канонизируются при парсинге;
        // корневой key или секция активного провайдера: resolveActiveProvider
        // уже скопировал его в effective-конфиг). nil — поведение как раньше.
        let cookieRelayProvider = config.transport == "cookie-relay"
            ? CookieRelayProvider.makeForCookieRelay(baseURL: config.baseURL)
            : nil
        // Единый реестр cookie-relay-провайдеров по baseURL (кука выпускается
        // на origin прокси; одинаковый baseURL → тот же origin → тот же
        // инстанс). Важно: реестр строится ОДИН раз в init и в замыкании
        // только читается — гонок нет, а failover/retry переиспользуют
        // ТОТ ЖЕ инстанс, что основной путь, вместе с его разогретым
        // токеном (иначе первый retry-запрос ушёл бы без куки на лишний
        // челлендж-раундтрип).
        var cookieRelayByURL: [String: CookieRelayProvider] = [:]
        if let cookieRelayProvider = cookieRelayProvider {
            cookieRelayByURL[config.baseURL] = cookieRelayProvider
        }
        for retryCandidate in config.providers {
            let t = retryCandidate.transport.isEmpty ? config.transport : retryCandidate.transport
            guard t == "cookie-relay", cookieRelayByURL[retryCandidate.baseURL] == nil,
                  let made = CookieRelayProvider.makeForCookieRelay(baseURL: retryCandidate.baseURL) else { continue }
            cookieRelayByURL[retryCandidate.baseURL] = made
        }
        let retryTransport = { (provider: AppConfig.Provider) -> CookieRelayProvider? in
            let t = provider.transport.isEmpty ? config.transport : provider.transport
            guard t == "cookie-relay" else { return nil }
            return cookieRelayByURL[provider.baseURL]
        }
        // Активный провайдер: явный active_provider, либо (по документированному
        // сценарию «только секции [providers.X], без active_provider») — первый
        // провайдер по порядку. От него зависит, КОГО исключать из failover-
        // очереди и какой адаптер запроса использует основной путь: повторять
        // падение основного провайдера при автоfailover нельзя.
        self.activeProviderID = config.activeProvider.isEmpty
            ? config.providers.first?.id
            : config.activeProvider
        self.failoverCandidates = config.failoverProviders(excluding: self.activeProviderID)
        var byID: [String: AppConfig.Provider] = [:]
        for provider in config.providers { byID[provider.id] = provider }
        self.providersByID = byID
        // Единый построитель Transcriber из полей секции провайдера + ОБЩИХ
        // настроек конфига (language/timeout/log_level/корневой proxyKeyHeader):
        // активный путь, failover/retry и роли маршрутизации ходят через него —
        // повторы и роли ведут себя как основной путь (тот же язык, таймаут и
        // уровень лога). id провайдера уходит в adapterID — известный провайдер
        // получает свой формат запроса (deepgram/giga-chat/…), неизвестный —
        // OpenAI-совместимый с собственными base_url/model из секции.
        let makeTranscriber = { (provider: AppConfig.Provider) -> Transcriber in
            Transcriber(
                baseURL: provider.baseURL,
                model: provider.model,
                apiKey: RetryProvider.resolveAPIKey(for: provider),
                proxyKey: provider.proxyKey,
                proxyKeyHeader: provider.proxyKeyHeader.isEmpty ? config.proxyKeyHeader : provider.proxyKeyHeader,
                language: config.language,
                timeout: config.timeoutSeconds,
                logLevel: config.logLevel,
                cookieRelayProvider: retryTransport(provider),
                httpProxy: provider.httpProxy.isEmpty ? config.httpProxy : provider.httpProxy,
                proxyUser: provider.proxyUser.isEmpty ? config.proxyUser : provider.proxyUser,
                proxyPassword: provider.proxyPassword.isEmpty ? config.proxyPassword : provider.proxyPassword,
                apiSecret: provider.apiSecret,
                adapterID: provider.id
            )
        }
        self.makeTranscriber = makeTranscriber
        // Активный транскрайбер — секцией активного провайдера через тот же
        // построитель (единая логика с failover/retry/ролями). Legacy-конфиг
        // (без секций) — ровно прежнее построение из effective-полей.
        if let activeID = self.activeProviderID, let activeProvider = byID[activeID] {
            self.transcriber = makeTranscriber(activeProvider)
        } else {
            self.transcriber = Transcriber(
                baseURL: config.baseURL,
                model: config.model,
                apiKey: config.apiKey,
                proxyKey: config.proxyKey,
                proxyKeyHeader: config.proxyKeyHeader,
                language: config.language,
                timeout: config.timeoutSeconds,
                logLevel: config.logLevel,
                cookieRelayProvider: cookieRelayProvider,
                httpProxy: config.httpProxy,
                proxyUser: config.proxyUser,
                proxyPassword: config.proxyPassword,
                apiSecret: config.apiSecret,
                adapterID: self.activeProviderID
            )
        }
        // Роли маршрутизации из [routing]: резолверы фолбэчат на активного;
        // пустой id (legacy-конфиг) → nil — роль не участвует, ровно текущее
        // поведение.
        let segmentRoleID = config.segmentProviderID()
        self.segmentRoleProviderID = segmentRoleID.isEmpty ? nil : segmentRoleID
        let finalRoleID = config.finalProviderID()
        self.finalRoleProviderID = finalRoleID.isEmpty ? nil : finalRoleID
        self.insertMethod = config.insertMethod
        self.autoFailover = config.autoFailover
        self.reviewBeforeInsert = config.reviewBeforeInsert
        // Failover/retry распознаёт СЕКЦИЕЙ провайдера через тот же построитель
        // (см. выше): повторы ведут себя как основной путь.
        self.retryProvider = RetryProvider(transcribeFunction: { wav, provider in
            let transcriber = makeTranscriber(provider)
            return try await transcriber.transcribe(wav: wav)
        })
        super.init()

        // Прогрев cookie-relay-токена: первый Alt+Alt не должен уходить с
        // протухшей/пустой кукой — фоновая заготовка токена стартует сразу
        // (неблокирующе для ввода).
        if let cookieRelayProvider = cookieRelayProvider {
            Task { _ = await cookieRelayProvider.refreshBlocking() }
        }

        self.audio.levelDelegate = self
        self.hotkeys.delegate = self

        // Принудительная остановка по жёсткому лимиту (60 с) идёт тем же путём,
        // что и обычный стоп: сэмплы → WAV → транскрибация.
        self.audio.onRecordingLimitReached = { [weak self] samples in
            DispatchQueue.main.async {
                self?.handleRecordingLimitReached(samples: samples)
            }
        }

        // Автоостановка по непрерывной тишине (~3 с): эквивалент повторного
        // Alt+Alt без нажатия — запись остановлена внутри AudioService, здесь
        // только финализация сэмплов тем же стандартным путём.
        self.audio.onAutoStop = { [weak self] samples in
            DispatchQueue.main.async {
                self?.handleAutoStop(samples: samples)
            }
        }

        // Ручной retry из dictatorctl: «Повторить распознавание другим провайдером».
        // CLI ставит distributed-нотификацию — агент распознаёт свой lastWAV из
        // памяти (доступность и вставка — как в обычном цикле).
        retryObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.dictation.agent.retryRequest"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            guard let userInfo = notification.userInfo,
                  let providerID = userInfo["provider"] as? String,
                  let provider = self.providersByID[providerID] else {
                Logger.log("retry request ignored: unknown provider payload", level: "error")
                return
            }
            self.handleRetryRequest(provider: provider)
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
        Logger.log(L10n.tr("error.accessibilityRequired"), level: "info")

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
            // Undo-окно: двойной Alt в пределах undoMaxInterval после успешной
            // вставки (state = .idle) стирает вставленный текст. Во всех
            // остальных состояниях Alt ведёт себя как раньше (см. .recording).
            if DictationFlow.shouldUndoInsteadOfStart(
                state: state,
                lastInsertedAt: lastInsertedAt,
                now: CFAbsoluteTimeGetCurrent(),
                undoWindow: undoMaxInterval
            ) {
                undoLastInsertion()
            } else {
                requestMicrophoneAndStart()
            }
        case .recording:
            if chunked {
                // Живая диктовка: останов (отдаст «хвост» в liveExecutor) +
                // финальный проход по всему WAV (тот же путь, что processChunked).
                liveFinalize()
            } else {
                sendRecording()
            }
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
            showMicrophoneError(L10n.tr("error.micPermission"))
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
                self.showMicrophoneError(L10n.tr("error.micPermissionUnhandled"))
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self = self, self.micRequestSession == session else { return }
                    self.micPermissionRequestInFlight = false
                    Logger.log("mic permission request result: \(granted ? "granted" : "denied")", level: "info")
                    granted ? self.startRecording()
                        : self.showMicrophoneError(L10n.tr("error.micPermission"))
                }
            }
        @unknown default:
            showMicrophoneError(L10n.tr("error.micPermission"))
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
        // Метка «через что идёт распознавание» («<провайдер> · <модель>») — из ТОГО
        // ЖЕ resolved-провайдера, которым в init собран распознаватель сессии
        // (resolvedConfig): единый источник истины, конфиг здесь не перечитывается.
        overlay.setSTTLabel(RecognitionLabel.forSession(resolvedConfig))
        // Фаза «запись»: микрофон + таймер, время старта фиксируется здесь.
        overlay.setRecordingPhase()
        overlay.setStatus(L10n.tr("overlay.recording"))
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
            self.showMicrophoneError(L10n.tr("error.micNoResponse"))
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
                if self.chunked {
                    // Живая диктовка: каждый уттеренс (пауза ≥ pauseDuration)
                    // распознаётся и вставляется на лету, к моменту Alt+Alt текст
                    // уже частично в поле ввода.
                    self.subscribeLiveDictation()
                }
                if self.isDebug {
                    Logger.log("record started: state = .recording", level: "debug")
                }
            case .failure(let error):
                Logger.log("microphone unavailable: \(error.localizedDescription)", level: "error")
                self.showMicrophoneError(L10n.tr("error.micEnableFailed"))
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
        if chunked {
            processChunked(samples)
            return
        }
        processSingleRequest(samples)
    }

    /// Обычный путь финализации записи: сэмплы → WAV → ОДНА транскрибация.
    /// Ровно текущее поведение (регрессионный путь при chunked = false).
    private func processSingleRequest(_ samples: [Int16]) {
        state = .transcribing
        // Новый цикл — токен отмены прошлого распознавания не действует.
        cancelRecognition = false
        // Фаза «обработка»: вместо иконки — анимация точек, пока идёт STT.
        overlay.setProcessingPhase()
        overlay.setStatus(L10n.tr("overlay.recognizing"))
        // Длительность по фактически собранным сэмплам (16 кГц моно) —
        // видно, в каких единицах уходит аудио в STT. Звук завершения играем
        // НЕ здесь, а в completeInsertion ПОСЛЕ вставки текста.
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
            // Последний WAV держим в памяти (RetryProvider): ручной retry другим
            // провайдером (`dictatorctl retry`) и автоfailover используют его же.
            self.retryProvider.store(wav: wav)

            do {
                let (result, providerID) = try await self.transcribeAutomatically(wav: wav)
                if let providerID = providerID {
                    Logger.log("transcription succeeded via failover provider '\(providerID)'", level: "info")
                }
                let text = TextRefinement.finalize(result.text)

                DispatchQueue.main.async {
                    // Страж доставки: сессия «обработка» активна (токен совпал,
                    // state все ещё .transcribing) И распознавание не отменено
                    // по Esc. Отмена по Esc ставит cancelRecognition и уводит
                    // state в .idle — текст вставлен не будет.
                    guard DictationFlow.shouldDeliverResult(
                        isCancelled: self.cancelRecognition,
                        sessionActive: self.processingSession == session && self.state == .transcribing
                    ) else { return }
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

    /// Пошаговая диктовка (chunked = true): VAD-сегментация записи → каждый
    /// сегмент отдельным запросом (prompt = уже распознанный текст) → инкре-
    /// ментальная вставка → финальный проход по всему WAV одним запросом →
    /// по-словный diff → замена изменившегося диапазона одним действием.
    private func processChunked(_ samples: [Int16]) {
        state = .transcribing
        // Новый цикл — токен отмены прошлого распознавания не действует
        // (тот же сброс, что и в processSingleRequest).
        cancelRecognition = false
        overlay.setProcessingPhase()
        overlay.setStatus(L10n.tr("overlay.recognizing"))
        sounds.playEnd()
        let duration = Double(samples.count) / 16000.0
        Logger.log(String(format: "chunked transcribe submit (\(samples.count) samples, %.2f s)", duration), level: "info")

        // Страж фазы «обработка»: несколько сегментов + финальный проход —
        // каждый запрос до networkRequestTimeout; сторож считает по числу
        // запросов (N сегментов, count > 1 ⇒ ещё +1 финальный). Тот же
        // механизм сессионного токена, что и в processSingleRequest.
        let segments = AudioSegmenter.segments(samples: samples)
        let requestCount = segments.count <= 1 ? 1 : segments.count + 1
        let chunkedMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5

        processingSession += 1
        let session = processingSession
        DispatchQueue.main.asyncAfter(deadline: .now() + chunkedMaxDuration) { [weak self] in
            guard let self = self,
                  self.processingSession == session,
                  self.state == .transcribing else { return }
            self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
        }

        Task { [weak self] in
            guard let self = self else { return }
            do {
                let outcome = try await ChunkedPipeline().run(
                    samples: samples,
                    stt: { wav, filename, prompt in
                        // Роли из [routing]: сегменты (filename "segment-N.wav")
                        // идут segment_provider, финальный проход по всему WAV
                        // ("final.wav") — final_provider. Роль не задана
                        // (= фолбэк на активного) — активный transcriber, ровно
                        // текущее поведение. Failover на ролях нет — провайдер
                        // роли используется напрямую. Сбой сегмента абортит весь
                        // прогон (ChunkedPipeline.run не ловит ошибки сегментов),
                        // финальный проход при этом не выполняется.
                        let selected: Transcriber
                        if filename == "final.wav" {
                            selected = self.roleTranscriber(self.finalRoleProviderID) ?? self.transcriber
                        } else {
                            selected = self.roleTranscriber(self.segmentRoleProviderID) ?? self.transcriber
                        }
                        let result = try await selected.transcribe(wav: wav, filename: filename, prompt: prompt)
                        return ChunkedPipeline.SttResult(text: result.text, words: result.words)
                    },
                    insert: { operation in
                        DispatchQueue.main.async {
                            // Тот же сессионный страж, что в single-пути: если
                            // сессия «обработки» сменилась или цикл завершён
                            // терминальным событием — вставка/статус no-op.
                            guard self.processingSession == session,
                                  self.state == .transcribing else { return }
                            switch operation {
                            case .appendSegment(let index, let text):
                                Inserter.append(text)
                                Logger.log("chunked append segment \(index + 1) (\(text.count) chars)", level: "info")
                            case .replaceTail(let old, let new):
                                Inserter.replaceRange(old: old, new: new)
                                Logger.log("chunked final replace: backspace \(old.count) chars, type \(new.count) chars", level: "info")
                            }
                        }
                    },
                    onPhase: { phase in
                        DispatchQueue.main.async {
                            // Страж от старого цикла, перезаписывающего статус
                            // новой диктовки или терминальное сообщение.
                            guard self.processingSession == session,
                                  self.state == .transcribing else { return }
                            switch phase {
                            case .segment(let index):
                                self.overlay.setStatus(L10n.tr("overlay.recognizingPart").replacingOccurrences(of: "{n}", with: "\(index + 1)"))
                            case .finalizing:
                                self.overlay.setStatus(L10n.tr("overlay.finalProcessing"))
                            }
                        }
                    }
                )
                DispatchQueue.main.async {
                    guard self.processingSession == session,
                          self.state == .transcribing else { return }
                    self.completeChunkedInsertion(outcome: outcome)
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

    /// Терминальная точка чанкового цикла: вставка уже сделана конвейером
    /// (append-операциями и финальной replace), здесь — финальные UX-решения
    /// (синтез с main-веткой): undo-бухгалтерия получает финальный текст сессии,
    /// review-гейт подтверждает/отменяет уже-напечатанный результат, пустой
    /// результат идёт тем же путём, что в single-пути (handleEmptyResult).
    private func completeChunkedInsertion(outcome: ChunkedPipeline.Outcome) {
        let text = outcome.insertedText

        // Пустой результат: конвейер ничего не напечатал (0 сегментов или
        // пустые транскрибации) — отдельный звук «пусто», undo-окно не
        // открывается, ровно как в single-пути (completeInsertion).
        if DictationFlow.outcome(for: text) == .empty {
            handleEmptyResult()
            return
        }

        // Ревью перед вставкой (review_before_insert = true): сегменты чанковой
        // сессии напечатаны конвейером инкрементально, поэтому гейт работает
        // финальным подтверждением — при отмене напечатанный текст стирается
        // целиком (одно действие delete), undo-окно при этом не открывается.
        if reviewBeforeInsert && hasInteractiveStdin {
            switch ReviewGate.confirm(text: text) {
            case .insert:
                break
            case .cancel:
                Inserter.delete(characters: text)
                overlay.resetPhase()
                overlay.setStatus(L10n.tr("overlay.cancelled"))
                hideAfter(0.8, reason: "chunked review cancelled")
                state = .idle
                Logger.log("chunked transcription cancelled by review gate")
                return
            }
        } else if reviewBeforeInsert {
            Logger.log("review_before_insert включён, но stdin не терминал — ревью чанка пропущено", level: "info")
        }

        // Бухгалтерия undo: двойной Alt в пределах undoMaxInterval стирает
        // финальный текст чанковой сессии одним действием.
        lastInsertedText = text
        lastInsertedAt = CFAbsoluteTimeGetCurrent()

        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.finishing"))
        sounds.playCompletionAfterInsert()
        hideAfter(0.8, reason: "chunked insert done")
        state = .idle
        Logger.log(
            "chunked transcription inserted: segments=\(outcome.segmentCount) finalized=\(outcome.finalized) finalChanged=\(outcome.finalChanged) (\(text.count) chars)",
            level: "info"
        )
        // Маркер для `dictatorctl last` — финальный текст чанковой сессии.
        Logger.log("LAST_TEXT: \(text.replacingOccurrences(of: "\n", with: " "))")
    }

    /// Запись остановлена по жёсткому лимиту (60 с / 960 000 сэмплов) —
    /// финализируем собранные сэмплы стандартным путём.
    private func handleRecordingLimitReached(samples: [Int16]) {
        guard state == .recording else { return }
        Logger.log("record limit reached (\(samples.count) samples)", level: "info")
        if chunked {
            // Живая диктовка: «хвост» уже отдан колбэком onSpeechSegment ДО
            // этого вызова (performForcedStop: tail → onRecordingLimitReached) и
            // стоит в liveExecutor первым; здесь — только страж и финальный
            // проход по переданным сэмплам (без audio.stop()).
            liveFinalizeFromSamples(samples)
        } else {
            processSamples(samples)
        }
    }

    /// Запись автоматически остановлена по непрерывной тишине (~3 с) — тот же
    /// путь, что и ручное повторное Alt+Alt: финализируем собранные сэмплы.
    /// Детектор жил в AudioService (там известна реальная длительность буферов),
    /// колбэк приходит на главной очереди; «хвост» live-диктовки уже отдан
    /// onSpeechSegment ДО этого вызова.
    private func handleAutoStop(samples: [Int16]) {
        guard state == .recording else { return }
        Logger.log("auto-stop by silence (\(samples.count) samples)", level: "info")
        if chunked {
            // Живая диктовка: «хвост» стоит в liveExecutor первым (tail был
            // доставлен onSpeechSegment раньше onAutoStop), здесь — финальный
            // проход по снимку. audio.stop() не вызываем: AudioService уже
            // разбирает движок своим путём (teardown на engineQueue).
            liveFinalizeFromSamples(samples)
        } else {
            processSamples(samples)
        }
    }

    // MARK: - Живая диктовка (chunked = true)

    /// Ставит live-подписку на речевые сегменты. Логика «кто сегодня отвечает
    /// за сегменты» фиксируется В МОМЕНТ ДОСТАВКИ: колбэк заменяется на новый
    /// при каждом старте, каждый захватывает свой токен сессии, и устаревший
    /// цикл не может обслужить сегменты нового (liveSession сменился, страж в
    /// handleLiveSegment отбрасывает).
    private func subscribeLiveDictation() {
        liveSession += 1
        let runState = LiveRunState(session: liveSession)
        liveRunState = runState
        audio.onSpeechSegment = { [weak self] segment, isTail in
            guard let self = self else { return }
            // Страж сессии: цикл отменён Esc / начат заново (liveSession
            // сменился) — сегмент старого цикла не обрабатываем.
            guard self.liveSession == runState.session else { return }
            self.liveExecutor.submit {
                await self.handleLiveSegment(segment, isTail: isTail, runState: runState)
            }
        }
    }

    /// Обработка одного доставленного сегмента (live-VAD или «хвост»). Всегда
    /// на liveExecutor — сегменты распознаются строго по очереди, накопленный
    /// prompt каждого следующего включает все предыдущие, «хвост» останова
    /// гарантированно обработан ДО финального прохода.
    private func handleLiveSegment(
        _ segmentSamples: [Int16],
        isTail: Bool,
        runState: LiveRunState
    ) async {
        let index = runState.segmentCount

        // Оверлей: «Распознаю… (часть N)» на время STT сегмента; фаза записи
        // остаётся (пользователь ещё говорит) — меняем только статус.
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.liveSession == runState.session,
                  self.state == .recording || self.state == .transcribing else { return }
            self.overlay.setStatus(L10n.tr("overlay.recognizingPart").replacingOccurrences(of: "{n}", with: "\(index + 1)"))
        }

        do {
            // Тот же per-segment путь, что и в offline-чанкинге (ChunkedPipeline.
            // recognizeSegment): WAV → STT с prompt-контекстом → финализация.
            // Failover здесь не нужен — финальный проход по всему WAV «докрутит»
            // ошибку (в offline-чанкинге сбой сегмента, напротив, абортит прогон).
            let result = try await ChunkedPipeline.recognizeSegment(
                samples: segmentSamples,
                index: index,
                insertedText: runState.insertedText,
                prompt: runState.promptParts.isEmpty ? nil : ChunkedPipeline.truncatedPrompt(runState.promptParts),
                stt: { wav, filename, prompt in
                    // Роль segment из [routing] — как в processChunked: провайдер
                    // сегментов; не задан — активный transcriber (failover здесь
                    // не нужен — финальный проход «докрутит»).
                    let transcriber = self.roleTranscriber(self.segmentRoleProviderID) ?? self.transcriber
                    let r = try await transcriber.transcribe(wav: wav, filename: filename, prompt: prompt)
                    return ChunkedPipeline.SttResult(text: r.text, words: r.words)
                },
                filename: "live-segment-\(index + 1).wav"
            )

            // Накопление — на liveExecutor ПОСЛЕ успешного STT: только
            // распознанный текст попадает в prompt следующего сегмента и в
            // базу финального diff.
            runState.insertedText += result.insertText
            runState.promptParts.append(result.promptText)
            runState.segmentCount += 1
            if isTail {
                runState.tailDelivered = true
            }

            DispatchQueue.main.async { [weak self] in
                guard let self = self,
                      self.liveSession == runState.session,
                      self.state == .recording || self.state == .transcribing else { return }
                // Инкрементальная вставка в поле ввода: «появляется постепенно».
                Inserter.append(result.insertText)
                Logger.log("live append segment \(index + 1) (\(result.insertText.count) chars)", level: "info")
                // Статус возвращается к фазе записи — кроме «хвоста» (идёт
                // фиксация: «Распознаю…» покажет страж/финальный проход).
                if self.state == .recording {
                    self.overlay.setStatus(L10n.tr("overlay.recording"))
                }
            }
        } catch {
            let networkText = OverlayErrorText.text(for: error)
            let message = networkText ?? Self.message(for: error)
            Logger.log(
                "live segment \(index + 1) failed: \(message) — фраза «докрутится» финальным проходом",
                level: "error"
            )
            // Сбой сегмента не прерывает диктовку: фраза целиком (или её часть)
            // будет распознана финальным проходом по ВСЕМУ WAV при фиксации.
            runState.anySegmentFailed = true
            // Запоминаем текст последней ошибки: если упадут ВСЕ сегменты
            // (segmentCount == 0, STT недоступен), финальный проход завершится
            // явной failTranscription с этим текстом, а не «Пустым результатом».
            runState.lastErrorText = message
        }
    }

    /// Фиксация живой диктовки (2-й Alt): останов → «хвост» незакрытого
    /// уттеренса уходит в liveExecutor (встаёт после незавершённых сегментов)
    /// → финальный проход по всему WAV → общий терминальный путь
    /// completeChunkedInsertion.
    private func liveFinalize() {
        guard state == .recording else { return }
        guard let runState = liveRunState else {
            // Логически недостижимо (подписка ставится при успешном старте
            // вместе с state = .recording) — страховочный путь в offline-чанкинг.
            sendRecording()
            return
        }

        // Фаза «обработка» — как в processChunked: страж на весь цикл, звук
        // завершения, статус распознавания.
        state = .transcribing
        cancelRecognition = false
        overlay.setProcessingPhase()
        overlay.setStatus(L10n.tr("overlay.recognizing"))
        sounds.playEnd()

        // Синхронный останов: незакрытый уттеренс отдаётся колбэком ДО возврата
        // stop() и уже стоит в liveExecutor первым в очереди финализации.
        let samples = audio.stop()
        let duration = Double(samples.count) / 16000.0
        Logger.log(String(format: "live finalize (\(samples.count) samples, %.2f s)", duration), level: "info")

        // Страж фазы «обработка»: незавершённые сегменты + «хвост» + финальный
        // проход — каждый запрос до networkRequestTimeout (запас на все).
        let requestCount = max(2, runState.segmentCount + 2)
        let liveMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5
        processingSession += 1
        let session = processingSession
        DispatchQueue.main.asyncAfter(deadline: .now() + liveMaxDuration) { [weak self] in
            guard let self = self,
                  self.processingSession == session,
                  self.state == .transcribing else { return }
            self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
        }

        liveExecutor.submit { [weak self] in
            guard let self = self else { return }
            await self.finishLiveRun(samples: samples, session: session, runState: runState)
        }
    }

    /// Финализация живого цикла по принудительному стопу (лимит длительности
    /// или автоостановке по тишине ~3 c). «Хвост» уже доставлен onSpeechSegment
    /// ДО этого вызова (порядок в performForcedStop: tail → колбэк) и стоит
    /// в liveExecutor первым; здесь — только страж и финальный проход по
    /// переданным сэмплам (без audio.stop()).
    private func liveFinalizeFromSamples(_ samples: [Int16]) {
        guard let runState = liveRunState else {
            processChunked(samples)
            return
        }
        state = .transcribing
        cancelRecognition = false
        overlay.setProcessingPhase()
        overlay.setStatus(L10n.tr("overlay.recognizing"))
        sounds.playEnd()
        let duration = Double(samples.count) / 16000.0
        Logger.log(String(format: "live limit finalize (\(samples.count) samples, %.2f s)", duration), level: "info")

        let requestCount = max(2, runState.segmentCount + 2)
        let liveMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5
        processingSession += 1
        let session = processingSession
        DispatchQueue.main.asyncAfter(deadline: .now() + liveMaxDuration) { [weak self] in
            guard let self = self,
                  self.processingSession == session,
                  self.state == .transcribing else { return }
            self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
        }

        liveExecutor.submit { [weak self] in
            guard let self = self else { return }
            await self.finishLiveRun(samples: samples, session: session, runState: runState)
        }
    }

    /// Финальный проход живого цикла (всегда на liveExecutor, ПОСЛЕ «хвоста»
    /// и всех сегментов — серийная очередь гарантирует порядок). «Один сегмент
    /// без пауз» — единственный сегмент это «хвост» (покрывает запись до
    /// конца) и ни один сегмент не сбоил: двойной STT-запрос не нужен (нечем
    /// «полировать»). Иначе — статический helper ChunkedPipeline.finalize (тот
    /// же путь, что и в offline-чанкинге): word-diff → замена одного диапазона.
    private func finishLiveRun(samples: [Int16], session: Int, runState: LiveRunState) async {
        // Пустая запись — без лишнего STT-запроса (недостижимо иначе, чем
        // процесс, но симметрично offline-чанкингу).
        if runState.segmentCount == 0 {
            // Полный сбой всех сегментов (STT недоступен: отключённая сеть /
            // провайдер): пользователь реально говорил, но ни один сегмент не
            // распознан. Это ошибка STT, а НЕ «пустая диктовка» — явная
            // failTranscription с текстом последней ошибки (как согласовано
            // с offline-чанкингом, ревью #112), а не маскирующий сбой «Пустой
            // результат» (звук Funk).
            if runState.anySegmentFailed {
                // Текст запоминается в catch handleLiveSegment; страховка на
                // недостижимый случай — стандартное сообщение таймаута.
                let message = runState.lastErrorText ?? Transcriber.sttTimeoutMessage
                DispatchQueue.main.async {
                    guard self.processingSession == session, self.state == .transcribing else { return }
                    self.failTranscription(message, isNetworkFailure: true)
                }
                return
            }
            let outcome = ChunkedPipeline.Outcome(
                segmentCount: 0, insertedText: "", finalized: false, finalChanged: false
            )
            DispatchQueue.main.async {
                guard self.processingSession == session, self.state == .transcribing else { return }
                self.completeChunkedInsertion(outcome: outcome)
            }
            return
        }

        // Единственный сегмент + «хвост» покрывает запись до конца + не было
        // сбоев — пропускаем финальный проход.
        if runState.segmentCount == 1 && runState.tailDelivered && !runState.anySegmentFailed {
            let outcome = ChunkedPipeline.Outcome(
                segmentCount: 1, insertedText: runState.insertedText, finalized: false, finalChanged: false
            )
            DispatchQueue.main.async {
                guard self.processingSession == session, self.state == .transcribing else { return }
                self.completeChunkedInsertion(outcome: outcome)
            }
            return
        }

        do {
            let result = try await ChunkedPipeline.finalize(
                samples: samples,
                insertedText: runState.insertedText,
                stt: { wav, filename, prompt in
                    // Роль final из [routing]: финальный проход по всей записи
                    // идёт провайдером роли; не задан — активный transcriber
                    // (ровно текущее поведение: без failover — роль выбрана явно).
                    let transcriber = self.roleTranscriber(self.finalRoleProviderID) ?? self.transcriber
                    let r = try await transcriber.transcribe(wav: wav, filename: filename, prompt: prompt)
                    return ChunkedPipeline.SttResult(text: r.text, words: r.words)
                },
                insert: { operation in
                    DispatchQueue.main.async {
                        guard self.processingSession == session, self.state == .transcribing else { return }
                        if case .replaceTail(let old, let new) = operation {
                            Inserter.replaceRange(old: old, new: new)
                            Logger.log("live final replace: backspace \(old.count) chars, type \(new.count) chars", level: "info")
                        }
                    }
                },
                onFinalizing: {
                    DispatchQueue.main.async {
                        guard self.processingSession == session, self.state == .transcribing else { return }
                        self.overlay.setStatus(L10n.tr("overlay.finalProcessing"))
                    }
                }
            )
            let outcome = ChunkedPipeline.Outcome(
                segmentCount: runState.segmentCount,
                insertedText: result.changed ? result.finalText : runState.insertedText,
                finalized: true,
                finalChanged: result.changed
            )
            DispatchQueue.main.async {
                guard self.processingSession == session, self.state == .transcribing else { return }
                self.completeChunkedInsertion(outcome: outcome)
            }
        } catch {
            let networkText = OverlayErrorText.text(for: error)
            let message = networkText ?? Self.message(for: error)
            DispatchQueue.main.async {
                guard self.processingSession == session, self.state == .transcribing else { return }
                self.failTranscription(message, isNetworkFailure: networkText != nil)
            }
        }
    }

    /// Вставка результата STT в активное приложение.
    /// Пустой результат (нет ни одной буквы/цифры) вставлять нельзя: мусор не
    /// появляется в тексте, вместо звука успеха — звук «пусто» (Funk), не чаще
    /// раза в 3 с. Одиночное слово — валидный результат, вставляется.
    /// Звук завершения играется ПОСЛЕ вставки (CGEvent), а не до неё.
    private func completeInsertion(_ text: String) {
        if DictationFlow.outcome(for: text) == .empty {
            handleEmptyResult()
            return
        }

        // Ревью перед вставкой (review_before_insert = true): текст печатается
        // в stdout, вставка только по Enter; Esc/другое — отмена. Под launchd
        // (агент без терминала) ReviewGate.confirm вернула бы nil → молчаливая
        // отмена ВСЕХ вставок — гейт пропускаем (текст вставляется как обычно).
        if reviewBeforeInsert && hasInteractiveStdin {
            switch ReviewGate.confirm(text: text) {
            case .insert:
                break
            case .cancel:
                overlay.resetPhase()
                overlay.setStatus(L10n.tr("overlay.cancelled"))
                hideAfter(0.8, reason: "review cancelled")
                state = .idle
                Logger.log("transcription cancelled by review gate")
                return
            }
        } else if reviewBeforeInsert {
            Logger.log("review_before_insert включён, но stdin не терминал (launchd?) — ревью пропущено", level: "info")
        }

        // Вставка текста выбранным способом (cgevent / clipboard) — единственная
        // операция, которую можно откатить undo-ом ниже (lastInserted*).
        Inserter.insert(text: text, method: insertMethod)
        lastInsertedText = text
        lastInsertedAt = CFAbsoluteTimeGetCurrent()

        // UI+звук — только после гарантированной вставки.
        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.finishing"))
        sounds.playCompletionAfterInsert()
        hideAfter(0.8, reason: "insert done")
        state = .idle
        Logger.log("transcription inserted (\(text.count) chars)")
        // Маркер для `dictatorctl last` (последний распознанный текст); переводы
        // строк заменяем, чтобы маркер остался одной строкой лога.
        Logger.log("LAST_TEXT: \(text.replacingOccurrences(of: "\n", with: " "))")
    }

    /// Транскрайбер роли маршрутизации (segment/final). Возвращает nil, когда роль
    /// не задана или указывает на активного провайдера — тогда вызывающий
    /// использует активный transcriber (строго текущее поведение). Иначе —
    /// прямой Transcriber провайдера роли из секции, БЕЗ failover-цепочки
    /// (роли выбраны явно; автоfailover остаётся только для основного пути).
    private func roleTranscriber(_ roleProviderID: String?) -> Transcriber? {
        guard let roleProviderID = roleProviderID,
              roleProviderID != activeProviderID,
              let provider = providersByID[roleProviderID] else {
            return nil
        }
        return makeTranscriber(provider)
    }

    /// Распознавание с автоматическим failover (auto_failover = true):
    /// основной провайдер — self.transcriber (активный из конфига); при
    /// TranscribeError пробуем кандидатов из failover-порядка. Ошибка, НЕ
    /// относящаяся к провайдеру (микрофон и т.п.), failover не запускает.
    /// Возвращает (результат, id failover-провайдера; nil — основной).
    private func transcribeAutomatically(wav: Data) async throws -> (TranscriptionResult, String?) {
        // Роль final из [routing] (целая запись не-chunked): задана и отлична
        // от активного — прямой провайдер роли БЕЗ failover-цепочки. Роль не
        // задана/совпадает с активным — ровно текущее поведение ниже.
        if let transcriber = roleTranscriber(finalRoleProviderID) {
            let result = try await transcriber.transcribe(wav: wav)
            return (result, nil)
        }
        do {
            let result = try await transcriber.transcribe(wav: wav)
            return (result, nil)
        } catch {
            guard autoFailover,
                  let transcribeError = error as? TranscribeError,
                  !failoverCandidates.isEmpty else {
                throw error
            }
            Logger.log("primary provider failed (\(transcribeError)) — trying failover providers",
                       level: "info")
            retryProvider.lastFailedProviderID = activeProviderID
            // Параллельный failover вынесен в DictationCore (тестируемая
            // функция): RetryProvider.parallelFailover — все кандидаты
            // запускаются одним withTaskGroup (независимые STT-запросы),
            // первый успех выигрывает и отменяет остальных (cancelAll);
            // TranscribeError-ы накапливаются — побеждает последний
            // завершившийся; не-TranscribeError прерывает цепочку, как в
            // последовательном цикле (микрофон и т.п.). lastFailedProviderID
            // стоит ДО группы и сбрасывается в retranscribe на успехе.
            return try await RetryProvider.parallelFailover(
                candidates: failoverCandidates
            ) { provider in
                guard let retryResult = try await self.retryProvider.retranscribe(with: provider) else {
                    throw TranscribeError.invalidResponse("failover retry lost the stored WAV")
                }
                return (retryResult, provider.id)
            }
        }
    }

    /// Обработка ручного retry из CLI (`dictatorctl retry <provider>`).
    /// Распознаёт последний WAV из памяти (если он есть) выбранным провайдером
    /// и вставляет результат стандартным путём (ревью/метод вставки учитываются).
    private func handleRetryRequest(provider: AppConfig.Provider) {
        guard retryProvider.hasLastRecording else {
            Logger.log("retry request ignored: no recording in this session", level: "info")
            return
        }
        let display = provider.name.isEmpty ? provider.id : provider.name
        Logger.log("retry with provider '\(display)' started", level: "info")
        Task { [weak self] in
            guard let self = self else { return }
            do {
                guard let result = try await self.retryProvider.retranscribe(with: provider) else {
                    Logger.log("retry with provider '\(display)': no stored WAV", level: "info")
                    return
                }
                let text = TextRefinement.finalize(result.text)
                DispatchQueue.main.async {
                    self.retryInsertion(text)
                }
            } catch {
                let networkText = OverlayErrorText.text(for: error)
                Logger.log("retry with provider '\(display)' failed: \(error)", level: "error")
                DispatchQueue.main.async {
                    // Показываем ошибку ТОЛЬКО если цикл диктовки не активен:
                    // иначе оверлей живого цикла («Записываю…»/«Распознаю…») затирается.
                    guard self.state == .idle else {
                        Logger.log("retry error ignored: dictation cycle active", level: "info")
                        return
                    }
                    self.overlay.resetPhase()
                    self.overlay.setStatus(L10n.tr("overlay.retryError").replacingOccurrences(of: "{message}", with: networkText ?? Self.message(for: error)))
                    self.hideAfter(2.0, reason: "retry failed")
                }
            }
        }
    }

    /// Вставка результата ручного retry: общий путь completeInsertion
    /// (ревью-гейт, способ вставки, маркер LAST_TEXT), но вне state-машины
    /// записи — retry не трогает state и сессию обработки.
    private func retryInsertion(_ text: String) {
        // Ретрай вне state-машины цикла: если пользователь уже начал новый цикл
        // (запись/распознавание), устаревший текст ретрая не вставляем и оверлей
        // живого цикла не трогаем.
        guard state == .idle else {
            Logger.log("retry result dropped: dictation cycle active (state=\(String(describing: state)))",
                       level: "info")
            return
        }
        if reviewBeforeInsert && hasInteractiveStdin {
            switch ReviewGate.confirm(text: text) {
            case .insert:
                break
            case .cancel:
                overlay.setStatus(L10n.tr("overlay.retryCancelled"))
                hideAfter(0.8, reason: "retry review cancelled")
                Logger.log("retry cancelled by review gate")
                return
            }
        } else if reviewBeforeInsert {
            Logger.log("review_before_insert включён, но stdin не терминал — ревью ретрая пропущено", level: "info")
        }
        Inserter.insert(text: text, method: insertMethod)
        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.retryInserted"))
        hideAfter(1.0, reason: "retry inserted")
        Logger.log("retry transcription inserted (\(text.count) chars)")
        Logger.log("LAST_TEXT: \(text.replacingOccurrences(of: "\n", with: " "))")
    }

    /// «Пустая» диктовка: STT вернул <2 слов (или тишину). Текст не вставляем,
    /// звук успеха не играем. Отдельный звук Funk вместо Basso — пустая
    /// диктовка это НЕ ошибка микрофона; cooldown пустых результатов отдельный.
    private func handleEmptyResult() {
        if emptyResultCooldown.allow(at: CFAbsoluteTimeGetCurrent()) {
            sounds.playEmptyResult()
        } else if isDebug {
            Logger.log("empty-result sound suppressed (cooldown active)", level: "debug")
        }
        // Свежая «вставка» не состоялась — undo-окно не открывается.
        lastInsertedText = nil
        lastInsertedAt = nil
        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.emptyResult"))
        hideAfter(0.8, reason: "empty result")
        state = .idle
        Logger.log("empty transcription result — not inserted", level: "info")
    }

    /// Откат последней вставки двойным Alt в пределах undoMaxInterval.
    /// Стираем ровно столько символов, сколько вставили (backspace — зеркало
    /// к Inserter.insert), статус оверлея — «Отмена вставки», звук отката —
    /// по конфигу (undo_sound_enabled). Может перезапустить оверлей, если панель
    /// успела скрыться после «Завершаю…».
    private func undoLastInsertion() {
        guard let text = lastInsertedText else {
            // Вставки нет (например, окно истекло при отложенном прерывании) —
            // закрываем undo-окно и уходим.
            lastInsertedAt = nil
            lastInsertedText = nil
            return
        }
        overlay.show()
        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.insertCancelled"))
        Inserter.delete(characters: text)
        if undoSoundEnabled {
            sounds.playUndo()
        }
        lastInsertedText = nil
        lastInsertedAt = nil
        // state уже .idle — следующий Alt+Alt начнёт новую запись.
        hideAfter(0.8, reason: "insertion undone")
        Logger.log("insertion undone (\(text.count) chars)")
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
        overlay.setStatus(L10n.tr("overlay.error").replacingOccurrences(of: "{message}", with: message))
        hideAfter(2.0, reason: "transcription failed")
        state = .idle
        Logger.log("transcription failed: \(message)", level: "error")
    }

    /// Esc: отмена текущей фазы. Ветки состояния специфичны только в первом шаге
    /// (recording — остановить движок; transcribing — поставить токен отмены,
    /// чтобы результат вернувшегося STT-запроса не вставлялся), далее общий
    /// терминальный хвост: статус «Отменено», звук отмены (Ping, НЕ Basso — это
    /// не ошибка), ровно один hide. Каждая терминальная точка планирует hide
    /// ровно один раз.
    private func handleCancel() {
        switch state {
        case .recording:
            audio.cancel()
            // Аннулируем живой цикл: сегмент, распознаваемый в моменте на
            // liveExecutor, не вставится (страж liveSession в handleLiveSegment).
            liveSession += 1
            liveRunState = nil
            Logger.log("record cancelled")
        case .transcribing:
            cancelRecognition = true
            Logger.log("recognition cancelled by Esc")
        case .idle:
            return
        }
        overlay.resetPhase()
        overlay.setStatus(L10n.tr("overlay.cancelled"))
        sounds.playCancel()
        hideAfter(0.8, reason: "cancelled")
        state = .idle
    }

    // MARK: - Helpers

    /// Стандартный ввод — терминал? ReviewGate читает stdin; под launchd (GUI-
    /// агент без терминала) гейт не блокирует и не отменяет вставки (см.
    /// completeInsertion/retryInsertion).
    private var hasInteractiveStdin: Bool {
        isatty(STDIN_FILENO) == 1
    }

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

/// Исключительный flock-лок синглтона: <tmp>/dictation-agent-<uid>.lock.
/// fd живёт в глобальной переменной весь процесс — лок снимается только при
/// завершении процесса. Второй инстанс (дубль launchd-старта) НЕ выходит из
/// процесса: оба LaunchAgent держат KeepAlive=true, и чистый exit ушёл бы в
/// бесконечный респавн. Вместо выхода — пассивное ожидание на главном run loop.
var instanceLockFD: Int32 = -1

/// Пытается занять singleton-лок. true — лок взят, сервисы можно стартовать;
/// false — уже работает другой инстанс (залогировано), процесс должен
/// простаивать, ничего не запуская.
@discardableResult
func ensureSingleInstance() -> Bool {
    let lockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictation-agent-\(getuid()).lock").path
    let fd = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
    guard fd >= 0 else {
        let error = errno
        Logger.log("single-instance lock open failed (errno \(error)): \(String(cString: strerror(error)))", level: "error")
        exit(1)
    }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
        let error = errno
        guard error == EWOULDBLOCK else {
            Logger.log("single-instance lock failed (errno \(error)): \(String(cString: strerror(error)))", level: "error")
            close(fd)
            exit(1)
        }
        Logger.log("another dictation agent instance already running — entering idle wait", level: "info")
        close(fd)
        return false
    }
    instanceLockFD = fd
    return true
}

// Singleton-гейт — первый исполняемый код, ДО загрузки конфига и ДО любых
// сервисов (HotkeyService, микрофон, STT, CGEvent-тап, observer'ы).
guard ensureSingleInstance() else {
    // Второй инстанс уже работает — пассивно ждём на главной dispatch queue.
    // dispatchMain() не требует run loop source и никогда не возвращается.
    dispatchMain()
    fatalError("unreachable: dispatchMain() returned")
}

let config: AppConfig
do {
    config = try AppConfig.load(from: nil)
} catch {
    Logger.log("config load failed: \(error.localizedDescription)", level: "error")
    config = AppConfig.defaults
}

// UI-язык из конфига — ДО первого использования L10n.tr (статические
// сообщения Transcriber.noInternetMessage/… резолвятся при первом доступе).
L10n.language = AppLanguage(rawValue: config.uiLanguage) ?? .en

let app = NSApplication.shared
let agent = Agent(config: config)

do {
    // Проверяет AXIsProcessTrusted(); если права нет — сам открывает системную
    // панель «Доступность» и опрашивает раз в 2 сек до выдачи права (автоподхват).
    try agent.startWithAccessibilityRequest()
} catch {
    Logger.log("hotkey service failed to start: \(error.localizedDescription)", level: "error")
    let alert = NSAlert()
    alert.messageText = L10n.tr("error.agentLaunchFailed")
    alert.informativeText = error.localizedDescription
    alert.runModal()
    exit(1)
}

// Фоновый агент: без иконки в Dock и без меню-бара приложения.
NSApp.setActivationPolicy(.accessory)

app.run()