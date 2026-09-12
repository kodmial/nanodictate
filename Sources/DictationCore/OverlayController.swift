import AppKit
import SwiftUI
import ApplicationServices
import QuartzCore

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

    public func show() {
        let point = caretPosition() ?? screenCenter()
        show(at: point)
    }

    public func show(at point: CGPoint) {
        ensurePanel()
        guard let panel = panel else { return }

        let panelWidth: CGFloat = 260
        let panelHeight: CGFloat = 120

        // Position above caret, clamped to the screen that contains the point
        // (coordinate system: origin = bottom-left of main screen, y grows upward)
        let fallbackScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) })?.frame
            ?? NSScreen.main?.frame ?? fallbackScreen
        let px = point.x - panelWidth / 2
        let py = point.y - panelHeight - 12 // above caret

        let x = min(max(px, screen.minX + 8), screen.maxX - panelWidth - 8)
        let y: CGFloat
        if py >= screen.minY + 8 {
            y = py
        } else {
            // Not enough room above — place below caret
            y = point.y + 12
        }

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
        panel.orderFront(nil)
        // Do NOT call NSApp.activate — keep focus on the current app
    }

    public func hide() {
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

    private func screenCenter() -> CGPoint {
        guard let screen = NSScreen.main else { return CGPoint(x: 720, y: 450) }
        return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
    }
}
