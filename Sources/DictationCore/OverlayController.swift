import AppKit
import SwiftUI
import ApplicationServices
import QuartzCore
import CoreGraphics

// MARK: - Observable State Bridge

/// Фаза оверлея: что именно показывает панель — только статус/ничего, запись
/// (микрофон + бегущий таймер) или обработку (анимация «три точки», пока идёт
/// STT-запрос).
enum OverlayPhase: Equatable {
    case idle
    case recording
    case processing
}

/// Форматирование времени записи для таймера: секунды → «m:ss» (7 → «0:07»).
/// Чистая функция вне SwiftUI, чтобы покрывалась юнит-тестами без вью.
public enum OverlayTimeFormat {
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds < 0 ? 0 : seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Bridges AppKit calls (updateLevel/setStatus) into SwiftUI reactivity.
final class OverlayState: ObservableObject {
    @Published var level: Float = 0
    @Published var status: String = ""
    @Published var phase: OverlayPhase = .idle
    /// Момент старта записи — источник истины для таймера. Передаётся из
    /// контроллера в момент старта; вью только тикает раз в секунду и считает
    /// разницу от него (не накапливает «если успели»).
    @Published var recordingStart: Date?

    func updateLevel(_ value: Float) {
        level = min(max(value, 0), 1)
    }

    func setStatus(_ text: String) {
        status = text
    }

    func setRecordingPhase(startedAt: Date = Date()) {
        recordingStart = startedAt
        phase = .recording
    }

    func setProcessingPhase() {
        phase = .processing
    }

    func resetPhase() {
        phase = .idle
        recordingStart = nil
    }
}

// MARK: - SwiftUI Content View

struct OverlayContentView: View {
    @ObservedObject var state: OverlayState

    @State private var displayedLevel: Float = 0
    @State private var displayedStatus: String = ""
    @State private var decayTimer: Timer?

    /// Текст таймера записи («0:00» / «1:07») — обновляется раз в секунду
    /// пересчётом от state.recordingStart, а не накоплением тиков.
    @State private var elapsedText: String = "0:00"
    @State private var clockTimer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if state.phase == .processing {
                    // Обработка: STT-запрос ушёл — вместо иконки анимация
                    // «три точки» (пульс opacity/scale, каскадная задержка).
                    ProcessingDots()
                } else {
                    // Outer pulsing rings (3 layers)
                    // opacity per spec: 0.6 - value*0.4, slightly staggered per layer
                    ForEach(0..<3, id: \.self) { i in
                        let stagger = Float(i) * 0.12
                        Circle()
                            .fill(Color.white)
                            .frame(width: 64, height: 64)
                            .scaleEffect(1.0 + CGFloat(displayedLevel) * 0.5 + CGFloat(i) * 0.15)
                            .opacity(Double(max(0, 0.6 - displayedLevel * 0.4 - stagger)))
                    }

                    // Main circle background
                    Circle()
                        .fill(Color.white.opacity(0.15 + Double(displayedLevel) * 0.25))
                        .frame(width: 64, height: 64)
                        .scaleEffect(1.0 + CGFloat(displayedLevel) * 0.3)

                    // Microphone icon
                    Image(systemName: "mic.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white)
                        .scaleEffect(1.0 + CGFloat(displayedLevel) * 0.15)
                }
            }
            .frame(width: 64, height: 64)
            .animation(.linear(duration: 0.1), value: displayedLevel)

            // Таймер записи: «0:07» под иконкой, пока идёт запись.
            if state.phase == .recording {
                Text(elapsedText)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            // Status text
            Text(displayedStatus)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
                .frame(minWidth: 100)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.8))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
        )
        .onAppear {
            displayedLevel = state.level
            displayedStatus = state.status
            if state.phase == .recording {
                startClock()
            }
        }
        .onDisappear {
            stopClock()
        }
        .onChange(of: state.level) { newValue in
            handleLevelChange(newValue)
        }
        .onChange(of: state.status) { newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedStatus = newValue
            }
        }
        .onChange(of: state.phase) { newPhase in
            // Таймер живёт только в фазе записи; в обработке его место
            // занимает анимация точек.
            if newPhase == .recording {
                startClock()
            } else {
                stopClock()
            }
        }
        .onChange(of: state.recordingStart) { _ in
            // Новый сеанс записи — таймер отсчитывается от свежего старта.
            startClock()
        }
    }

    // MARK: - Таймер записи

    /// Запускает/перезапускает секундный таймер: значение всегда пересчитывается
    /// от state.recordingStart (источник истины — момент старта записи),
    /// а не накапливается тиками.
    private func startClock() {
        clockTimer?.invalidate()
        refreshElapsedText()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            self.refreshElapsedText()
        }
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private func refreshElapsedText() {
        guard let start = state.recordingStart else {
            elapsedText = "0:00"
            return
        }
        elapsedText = OverlayTimeFormat.format(Date().timeIntervalSince(start))
    }

    private func handleLevelChange(_ newLevel: Float) {
        decayTimer?.invalidate()

        if newLevel > 0 {
            withAnimation(.linear(duration: 0.1)) {
                displayedLevel = newLevel
            }
        } else {
            // Soft decay when level drops to 0
            var decay: Float = displayedLevel
            decayTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                decay *= 0.85
                if decay < 0.01 {
                    withAnimation(.linear(duration: 0.15)) {
                        self.displayedLevel = 0
                    }
                    timer.invalidate()
                } else {
                    withAnimation(.linear(duration: 0.05)) {
                        self.displayedLevel = decay
                    }
                }
            }
        }
    }
}

/// Анимация «обработка»: три точки, мягко пульсируют каскадом (opacity/scale).
/// Дешёвые для CPU анимации; перезапускаются при каждом появлении фазы за счёт
/// свежего @State в подвью.
private struct ProcessingDots: View {
    @State private var animate = false

    var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color.white)
                    .frame(width: 10, height: 10)
                    .scaleEffect(animate ? 1.0 : 0.35)
                    .opacity(animate ? 1.0 : 0.35)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                        value: animate
                    )
            }
        }
        .onAppear {
            animate = true
        }
    }
}

/// Чистая логика позиционирования панели: без AppKit-окна, на входе только
/// точка (каретка), экран и размер панели. Вынесена отдельно, чтобы поведение
/// «панель всегда видна, над кареткой, не вылезает за экран» покрывалось
/// юнит-тестами без создания реального окна.
public enum OverlayLayout {

    /// Возвращает frame панели размером `panelSize` рядом с точкой `point`
    /// внутри экрана `screen`. Панель встаёт НАД точкой (с отступом 12pt);
    /// если над точкой нет места — ПОД точкой. В любом случае frame клампится
    /// в границы экрана, так что панель никогда не пропадает за его край.
    public static func panelFrame(
        near point: CGPoint,
        inside screen: CGRect,
        panelSize: CGSize
    ) -> CGRect {
        let gap: CGFloat = 12
        let minMargin: CGFloat = 8

        let px = point.x - panelSize.width / 2
        let pxClamped = min(max(px, screen.minX + minMargin), screen.maxX - panelSize.width - minMargin)

        let aboveY = point.y - panelSize.height - gap
        if aboveY >= screen.minY + minMargin {
            return CGRect(x: pxClamped, y: aboveY, width: panelSize.width, height: panelSize.height)
        }
        let belowY = point.y + gap
        return CGRect(x: pxClamped, y: belowY, width: panelSize.width, height: panelSize.height)
    }

    /// Возвращает screen-канвас для точки (координатная математика выше).
    public static func screenContaining(_ point: CGPoint) -> CGRect {
        if let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return screen.frame
        }
        return NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    /// Чистая цепочка фоллбэков выбора точки показа панели:
    /// (а) каретка, если она передана и валидна (обычно — AX-каретка внутри
    ///     экрана; проверка инъецируется через `isValid`);
    /// (б) иначе позиция мыши, если валидна;
    /// (в) иначе центр экрана.
    ///
    /// Вынесена из OverlayController.positionedPoint(), чтобы решающая логика
    /// тестировалась без AX/NSEvent — три точки и замыкание валидности
    /// подаются снаружи.
    public static func resolvePoint(
        caret: CGPoint?,
        mouse: CGPoint,
        screenCenter: CGPoint,
        isValid: (CGPoint) -> Bool
    ) -> CGPoint {
        if let caret = caret, isValid(caret) {
            return caret
        }
        if isValid(mouse) {
            return mouse
        }
        return screenCenter
    }
}

public final class OverlayController: NSObject {
    private var panel: NSPanel?
    private let state = OverlayState()
    /// Точка показа из последнего show(at:) — на неё пересчитывается frame
    /// при смене фазы (высота панели зависит от фазы: таймер/точки).
    private var anchorPoint: CGPoint?

    /// Уровень логирования: при `"debug"` в agent.log уходят флаги окна
    /// (isKeyWindow/isMainWindow/level/styleMask) при показе/скрытии.
    private let logLevel: String

    public init(logLevel: String = "info") {
        self.logLevel = logLevel
        super.init()
    }

    private var isDebug: Bool { logLevel.lowercased() == "debug" }
    deinit {
        hide()
    }

    // MARK: - Public API

    public var isVisible: Bool {
        return panel?.isVisible ?? false
    }

    /// Frame панели — для тестов (проверка, что панель реально зафреймлена
    /// рядом с кареткой и не уехала за экран).
    var testPanelFrame: CGRect? {
        return panel?.frame
    }

    /// Сама панель — для тестов: повторные show() не должны порождать новые
    /// окна (проверяется идентичность панели).
    var testPanel: NSPanel? {
        return panel
    }

    /// Состояние оверлея — для тестов (фазы записи/обработки, время старта).
    var testState: OverlayState? {
        return state
    }

    public func show() {
        // Цепочка фоллбэков: AX-каретка → мышь → центр главного экрана.
        show(at: positionedPoint())
    }

    public func show(at point: CGPoint) {
        anchorPoint = point
        ensurePanel()
        guard let panel = panel else {
            Logger.log("overlay show: panel is nil", level: "error")
            return
        }

        let panelWidth: CGFloat = 260
        let panelHeight = desiredPanelHeight()

        // Рендер-усиление для фонового агента без .app-бандла: принудительная
        // активация (без перехвата фокуса — ignoringOtherApps:false) до порядка
        // фронт, чтобы WindowServer реально вывел окно поверх чужого приложения.
        NSApp.activate(ignoringOtherApps: false)

        let screen = OverlayLayout.screenContaining(point)
        let frame = OverlayLayout.panelFrame(
            near: point,
            inside: screen,
            panelSize: CGSize(width: panelWidth, height: panelHeight)
        )

        panel.setFrame(frame, display: true)
        panel.level = .statusBar
        // .canJoinAllSpaces + .fullScreenAuxiliary — панель видна во всех Space,
        // включая поверх полноэкранных приложений. (уже настроено в ensurePanel,
        // но повторяем здесь на случай пересоздания окна между сеансами)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // orderFront(nil) НЕ показывает окно из неактивного фонового агента —
        // orderFrontRegardless покажет панель без активации приложения.
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        if isDebug {
            let flags = [
                "isVisible=\(panel.isVisible)",
                "isKeyWindow=\(panel.isKeyWindow)",
                "isMainWindow=\(panel.isMainWindow)",
                "isFloatingPanel=\(panel.isFloatingPanel)",
                "worksWhenModal=\(panel.worksWhenModal)",
                "level=\(panel.level.rawValue)",
                "styleMask=\(panel.styleMask.rawValue)",
                "occlusion=\(panel.occlusionState.contains(.visible) ? "visible" : "occluded")",
            ].joined(separator: " ")
            Logger.log("overlay show flags: \(flags)", level: "debug")
        }

        Logger.log(
            "overlay show at (\(point.x), \(point.y)) frame=\(NSStringFromRect(frame)) screen=\(NSStringFromRect(screen)) visible=\(panel.isVisible)",
            level: "info"
        )

        // Отложенная проверка того, что окно РЕАЛЬНО попало на экран
        // (CGWindowList видит только окна, показанные WindowServer'ом).
        scheduleRenderCheck()
    }

    public func hide(reason: String? = nil) {
        // Логируем только если панель реально была видна: ветка «mic denied»
        // доходит до hide, не показывая панель вовсе, и логировать hide как
        // событие/ошибку там не нужно (микрофонный шум в логе).
        let wasVisible = panel?.isVisible == true
        if isDebug {
            Logger.log("overlay hide" + (reason.map { " reason=\($0)" } ?? "") + " wasVisible=\(wasVisible)", level: "debug")
        }
        if wasVisible {
            Logger.log("overlay hide" + (reason.map { " reason=\($0)" } ?? ""), level: "info")
        }
        // Скрытый оверлей не должен держать таймер или точки: сброс фазы
        // в базовую, следующий сеанс стартует с чистого состояния.
        state.resetPhase()
        panel?.orderOut(nil)
    }

    public func updateLevel(_ value: Float) {
        state.updateLevel(value)
    }

    public func setStatus(_ text: String) {
        state.setStatus(text)
    }

    // MARK: - Фазы оверлея

    /// Фаза «запись»: микрофон + бегущий таймер. Момент старта фиксируется
    /// здесь (можно передать извне) — вью считает секунды от него.
    public func setRecordingPhase(startedAt: Date = Date()) {
        state.setRecordingPhase(startedAt: startedAt)
        resizePanelForCurrentPhase()
    }

    /// Фаза «обработка»: три точки вместо иконки, пока идёт STT-запрос.
    public func setProcessingPhase() {
        state.setProcessingPhase()
        resizePanelForCurrentPhase()
    }

    /// Возврат к базовой фазе (статус без таймера/точек) — терминальные точки
    /// цикла: вставка текста, ошибка, отмена.
    public func resetPhase() {
        state.resetPhase()
        resizePanelForCurrentPhase()
    }

    // MARK: - Размер панели под фазу

    /// Высота панели зависит от фазы: при записи под иконкой живёт таймер
    /// («0:07»), панель чуть выше; в остальных фазах — компактная.
    private func desiredPanelHeight() -> CGFloat {
        switch state.phase {
        case .recording: return 168
        case .idle, .processing: return 120
        }
    }

    /// Пересчитывает frame панели после смены фазы: высота меняется (таймер
    /// добавляет ~50pt), а панель остаётся привязана к той же точке показа.
    private func resizePanelForCurrentPhase() {
        guard let panel = panel, let point = anchorPoint else { return }
        let screen = OverlayLayout.screenContaining(point)
        let frame = OverlayLayout.panelFrame(
            near: point,
            inside: screen,
            panelSize: CGSize(width: panel.frame.width, height: desiredPanelHeight())
        )
        panel.setFrame(frame, display: true)
    }

    // MARK: - Panel Setup

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.allowsToolTipsWhenApplicationIsInactive = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        let hostingView = NSHostingView(rootView: OverlayContentView(state: state))
        hostingView.frame = panel.contentView!.bounds
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hostingView)

        self.panel = panel
        if isDebug {
            Logger.log("overlay panel created styleMask=\(panel.styleMask.rawValue) level=\(panel.level.rawValue)", level: "debug")
        }
    }

    // MARK: - Accessibility Positioning

    private func caretPosition() -> CGPoint? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let focusResult = AXUIElementCopyAttributeValue(
            axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement
        )
        guard focusResult == .success, let element = focusedElement else { return nil }

        let axElement = element as! AXUIElement

        var positionValue: AnyObject?
        let posResult = AXUIElementCopyAttributeValue(
            axElement, kAXPositionAttribute as CFString, &positionValue
        )
        guard posResult == .success, let posVal = positionValue else { return nil }

        var position = CGPoint.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position) else { return nil }

        var size = CGSize.zero
        var sizeValue: AnyObject?
        let sizeResult = AXUIElementCopyAttributeValue(
            axElement, kAXSizeAttribute as CFString, &sizeValue
        )
        if sizeResult == .success, let sizeVal = sizeValue {
            AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
        }

        // AX coordinates: origin at the top-left of the main screen, y grows downward.
        // AppKit coordinates: origin at the bottom-left of the main screen, y grows upward.
        // Caret anchor per spec: position + (width/2, 0) in AX space, then flipped to AppKit.
        let mainScreen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cx = position.x + size.width / 2
        let cy = mainScreen.maxY - position.y
        return CGPoint(x: cx, y: cy)
    }

    // MARK: - Позиционирование с фоллбэками

    /// Проверяет, что точка лежит внутри какого-либо реального экрана
    /// (небольшой запас -1pt, чтобы точки ровно на границе не отбрасывались).
    private func isValidScreenPoint(_ point: CGPoint) -> Bool {
        return NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
    }

    /// Цепочка фоллбэков для точки показа панели: собирает реальные точки
    /// (AX-каретка переднего приложения, позиция мыши в AppKit-координатах,
    /// центр главного экрана) и делегирует решающую логику чистой функции
    /// OverlayLayout.resolvePoint. Выбранный источник логируется — видно,
    /// какой фоллбэк сработал.
    private func positionedPoint() -> CGPoint {
        let caret = caretPosition()
        let mouse = NSEvent.mouseLocation
        let center = screenCenter()
        let point = OverlayLayout.resolvePoint(
            caret: caret,
            mouse: mouse,
            screenCenter: center,
            isValid: isValidScreenPoint
        )
        if let caret = caret, point == caret {
            Logger.log("overlay point source: AX caret (\(caret.x), \(caret.y))", level: "info")
        } else if point == mouse {
            Logger.log("overlay point source: mouse (\(mouse.x), \(mouse.y))", level: "info")
        } else {
            Logger.log("overlay point source: screen center (\(point.x), \(point.y))", level: "info")
        }
        return point
    }

    // MARK: - Проверка рендера (CGWindowList)

    /// Через 0.5 c после orderFrontRegardless проверяет, видит ли WindowServer
    /// окно агента (CGWindowListCopyWindowInfo). Доказывает, реально ли панель
    /// на экране, или окно создано, но не отрендерено.
    private func scheduleRenderCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.logRenderCheck()
        }
    }

    private func logRenderCheck() {
        // Быстрый стоп/отмена прячет панель легально раньше, чем придёт проверка —
        // в этом случае окна нет по делу, и логировать «NO DictatorAgent window»
        // как ошибку не нужно.
        guard isVisible else { return }
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            Logger.log("overlay render check: CGWindowListCopyWindowInfo unavailable", level: "error")
            return
        }
        let matches = windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "DictatorAgent" }
        guard !matches.isEmpty else {
            Logger.log("overlay render check: NO DictatorAgent window on screen after 0.5s", level: "error")
            return
        }
        for window in matches {
            let bounds = window[kCGWindowBounds as String] ?? "unknown"
            let layer = window[kCGWindowLayer as String] ?? "unknown"
            let onscreen = window[kCGWindowIsOnscreen as String] ?? "unknown"
            Logger.log("overlay render check: on-screen window bounds=\(bounds) layer=\(layer) isOnscreen=\(onscreen)", level: "info")
        }
    }

    private func screenCenter() -> CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 720, y: 450) }
        return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    }
}
