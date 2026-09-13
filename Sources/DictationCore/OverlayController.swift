import AppKit
import SwiftUI
import ApplicationServices
import QuartzCore
import CoreGraphics

// MARK: - Observable State Bridge

/// Bridges AppKit calls (updateLevel/setStatus) into SwiftUI reactivity.
final class OverlayState: ObservableObject {
    @Published var level: Float = 0
    @Published var status: String = ""

    func updateLevel(_ value: Float) {
        level = min(max(value, 0), 1)
    }

    func setStatus(_ text: String) {
        status = text
    }
}

// MARK: - SwiftUI Content View

struct OverlayContentView: View {
    @ObservedObject var state: OverlayState

    @State private var displayedLevel: Float = 0
    @State private var displayedStatus: String = ""
    @State private var decayTimer: Timer?

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
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
            .animation(.linear(duration: 0.1), value: displayedLevel)

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
        }
        .onChange(of: state.level) { newValue in
            handleLevelChange(newValue)
        }
        .onChange(of: state.status) { newValue in
            withAnimation(.easeInOut(duration: 0.2)) {
                displayedStatus = newValue
            }
        }
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

// MARK: - OverlayController

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
}

public final class OverlayController: NSObject {
    private var panel: NSPanel?
    private let state = OverlayState()

    public override init() {
        super.init()
    }

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

    public func show() {
        // Цепочка фоллбэков: AX-каретка → мышь → центр главного экрана.
        guard let point = positionedPoint() else { return }
        show(at: point)
    }

    public func show(at point: CGPoint) {
        ensurePanel()
        guard let panel = panel else {
            Logger.log("overlay show: panel is nil", level: "error")
            return
        }

        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 120

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

        Logger.log(
            "overlay show at (\(point.x), \(point.y)) frame=\(NSStringFromRect(frame)) screen=\(NSStringFromRect(screen)) visible=\(panel.isVisible)",
            level: "info"
        )

        // Отложенная проверка того, что окно РЕАЛЬНО попало на экран
        // (CGWindowList видит только окна, показанные WindowServer'ом).
        scheduleRenderCheck()
    }

    public func hide(reason: String? = nil) {
        if reason != nil || panel?.isVisible == true {
            Logger.log("overlay hide" + (reason.map { " reason=\($0)" } ?? ""), level: "info")
        }
        panel?.orderOut(nil)
    }

    public func updateLevel(_ value: Float) {
        state.updateLevel(value)
    }

    public func setStatus(_ text: String) {
        state.setStatus(text)
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

    /// Цепочка фоллбэков для точки показа панели:
    /// (а) AX-каретка переднего приложения, если валидна и внутри экрана;
    /// (б) иначе позиция мыши (NSEvent.mouseLocation — AppKit-координаты,
    ///     совпадают с пространством NSScreen.frame);
    /// (в) иначе центр главного экрана.
    /// Выбранная точка логируется — видно, какой фоллбэк сработал.
    private func positionedPoint() -> CGPoint? {
        if let caret = caretPosition(), isValidScreenPoint(caret) {
            Logger.log("overlay point source: AX caret (\(caret.x), \(caret.y))", level: "info")
            return caret
        }
        let mouse = NSEvent.mouseLocation
        if isValidScreenPoint(mouse) {
            Logger.log("overlay point source: mouse (\(mouse.x), \(mouse.y))", level: "info")
            return mouse
        }
        let center = screenCenter()
        Logger.log("overlay point source: screen center (\(center.x), \(center.y))", level: "info")
        return center
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
