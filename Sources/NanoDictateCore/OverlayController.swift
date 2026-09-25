import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import SwiftUI

// swiftlint:disable file_length

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
  /// Ярлык «через что идёт распознавание» («groq · whisper-large-v3»).
  /// Приходит от агента в момент старта диктовки — оверлей сам конфиг
  /// не читает и сам ярлык не строит.
  @Published var sttLabel: String = ""

  func updateLevel(_ value: Float) {
    level = min(max(value, 0), 1)
  }

  func setStatus(_ text: String) {
    status = text
  }

  func setSTTLabel(_ text: String) {
    sttLabel = text
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
    // Ярлык живёт только в течение цикла записи/распознавания: сброс при
    // возврате к базовой фазе (и в hide() через этот же метод) не даёт
    // метке ПРОШЛОЙ сессии остаться на панели статуса — прежде всего на
    // «Отмена вставки» (undo-путь повторно вызывает show()+resetPhase() без
    // setSTTLabel). В начале нового цикла агент всегда заново зовёт
    // setSTTLabel сразу после show(), так что свежая метка не затирается.
    sttLabel = ""
  }
}

// MARK: - SwiftUI Content View

struct OverlayContentView: View {
  @ObservedObject var state: OverlayState

  /// Сглаженный метр (dB-ремап + envelope-баллистика) — крутит кольцо-дугу.
  @State private var meter: Float = 0
  /// Целевой метр из последнего пришедшего RMS (envelope догоняет его).
  @State private var meterTarget: Float = 0
  /// Следящий пик метра — пик-точка кольца.
  @State private var peak: Float = 0
  @State private var peakTracker = OverlayPeak()
  /// Тик-луп баллистики (attack/release) — идёт, пока есть что сглаживать.
  @State private var meterTimer: Timer?

  @State private var displayedStatus: String = ""

  /// Текст таймера записи («0:00» / «1:07») — обновляется раз в секунду
  /// пересчётом от state.recordingStart, а не накоплением тиков.
  @State private var elapsedText: String = "0:00"
  @State private var clockTimer: Timer?

  /// Шаг тик-лупа баллистики: 20 Гц ловят и быстрый attack (70 мс), и
  /// заметный release без лишней нагрузки на SwiftUI (изменения < 0.0015
  /// не перерисовываются).
  private let meterTick: TimeInterval = 0.05

  /// Шапка рендерится из ДВУХ значений — провайдер и модель отдельно
  /// (иерархия «кто распознаёт»), а не из одной склеенной строки.
  /// Значение приходит от агента одной строкой (setSTTLabel) — раскладываем
  /// её чистой функцией RecognitionLabel.parts(fromLabel:).
  private var headerParts: RecognitionLabel.RecognitionLabelParts {
    RecognitionLabel.parts(fromLabel: state.sttLabel)
  }

  var body: some View {
    VStack(spacing: 8) {
      // Шапка: «провайдер / модель» вертикально — две строки, а не
      // «провайдер · модель» по горизонтали: модель уходит на 2-ю
      // строку и НЕ расширяет панель. Кегли .caption — компактнее
      // текущего; провайдер — secondary, модель — tertiary (иерархия
      // «кто распознаёт»). Hairline-разделитель под шапкой УБРАН:
      // у macOS-панелей внутренних разделителей нет. При обработке
      // шапка притухает — статус-точки ниже говорят сами за себя.
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          // Фикс-слот под REC-точку (видна только при записи): пустой
          // слот держит ширину и в остальных фазах, чтобы провайдер
          // не прыгал при idle→recording→processing.
          ZStack {
            if state.phase == .recording {
              RECDot()
            }
          }
          .frame(width: 10, height: 10)
          Text(headerParts.provider)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 0)
        }
        if !headerParts.model.isEmpty {
          Text(headerParts.model)
            .font(.caption)
            .foregroundStyle(.tertiary)  // иерархия: модель ступенью ниже
            .lineLimit(2)
            .truncationMode(.middle)
        }
      }
      .opacity(state.phase == .processing ? 0.3 : 1)

      ZStack {
        if state.phase == .processing {
          // Обработка: STT-запрос ушёл — вместо иконки анимация
          // «три точки» (пульс opacity/scale, каскадная задержка).
          ProcessingDots()
        } else {
          // База индикатора — статичный фон-кольцо под дугой (как у
          // нативных level-индикаторов macOS): 12% системного
          // secondary, без пульсаций.
          Circle()
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 68, height: 68)

          // Кольцо-дуга вокруг микрофона: trim 0…метр (старт снизу,
          // угол −90°), штрих растёт 3→9. Вне записи дуга гаснет —
          // фидбек живёт только в VU-фазе. Цвет — системный
          // accentColor (controlAccentColor): БЕЗ градиентов и
          // цветовых зон — статус-текст ниже несёт семантику (HIG:
          // не полагаться только на цвет).
          ZStack {
            Circle()
              .trim(from: 0, to: CGFloat(min(max(meter, 0), 1)))
              .stroke(
                Color.accentColor,
                style: StrokeStyle(
                  lineWidth: OverlayLevel.strokeWidth(forMeter: meter),
                  lineCap: .round
                )
              )
              .frame(width: 68, height: 68)
            // Пик-точка на радиусе кольца: держит максимум ~0.8 с,
            // потом плавно опадает. Угол — в трим-пространстве дуги.
            Circle()
              .fill(Color.accentColor)
              .frame(width: 5, height: 5)
              .offset(x: 34)
              .rotationEffect(.degrees(Double(min(max(peak, 0), 1)) * 360))
          }
          .rotationEffect(.degrees(-90))
          .opacity(state.phase == .recording ? 1.0 : 0.25)

          // Микрофон (SF Symbol "mic.fill") — статичный, secondary:
          // уровень показывает дуга, а не иконка.
          Image(systemName: "mic.fill")
            .font(.system(size: 24, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      .frame(width: 68, height: 68)

      // Таймер записи: «0:07» под иконкой, пока идёт запись.
      if state.phase == .recording {
        Text(elapsedText)
          .font(.headline)
          .monospacedDigit()
          .foregroundStyle(.primary)
      }

      // Status text: перенос на 2 строки (длинные статус-строки
      // обрезаются, а не расширяют панель своим minWidth).
      Text(displayedStatus)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    // HUD-канон: материал панели — .regularMaterial (HIG: standard
    // overlays; .ultraThickMaterial читается плашкой), радиус 10pt
    // обрезается через shaped-background (как card macOS 12); собственная
    // тень РИСУЕТСЯ САМИ вью (прозрачному borderless-окну WindowServer
    // системную тень почти не рендерит, hasShadow не гарантирует
    // видимость) — применяется ПОСЛЕ clipShape, чтобы halo не был
    // обрезан маской: визуально это и есть слой тени под материалом.
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 24, x: 0, y: 8)
    .onAppear {
      displayedStatus = state.status
      if state.phase == .recording {
        startClock()
      }
      // Новый сеанс: атакующий догон до текущего уровня (при записи).
      meterTarget =
        state.phase == .recording
        ? OverlayLevel.meter(fromRMS: state.level)
        : 0
      ensureMeterLoopRunning()
    }
    .onDisappear {
      stopClock()
      stopMeterLoop()
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
        // Вне записи уровень не приходит — гасим цель, envelope
        // домогает спад и луп останавливается сам.
        meterTarget = 0
      }
      ensureMeterLoopRunning()
    }
    .onChange(of: state.recordingStart) { newStart in
      // Новый сеанс записи — таймер отсчитывается от свежего старта. Сброс
      // (nil) приходит в том же update, что и фаза .idle; порядок обработчиков
      // не гарантирован — не заводить часы вне фазы записи.
      if newStart != nil, state.phase == .recording {
        startClock()
      } else {
        stopClock()
      }
      ensureMeterLoopRunning()
    }
  }

  // MARK: - VU-баллистика (dB-ремап + envelope + пик)

  /// Reduce Motion (System Settings → Accessibility): при включённом —
  /// никакой плавной баллистики/пульсаций, метр и пик следуют за целью
  /// напрямую. Доступно с macOS 10.15 — под macOS 12 это штатная API.
  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Новый RMS из аудиопотока → целевой метр (dB-ремап). Лупу баллистики
  /// при этом гарантированно запускаем (или она уже идёт).
  private func handleLevelChange(_ newRMS: Float) {
    let newTarget = OverlayLevel.meter(fromRMS: newRMS)
    if abs(newTarget - meterTarget) > 0.0001 {
      meterTarget = newTarget
      ensureMeterLoopRunning()
    }
  }

  /// Луп баллистики живёт, пока есть что сглаживать: фаза записи, целевой
  /// метр или остывающий метр. Когда всё улеглось — останавливается и
  /// сбрасывается (пик тоже), чтобы следующая сессия стартовала с нуля.
  private func ensureMeterLoopRunning() {
    let needsLoop = state.phase == .recording || meterTarget > 0.001 || meter > 0.001
    if needsLoop {
      if meterTimer == nil {
        meterTimer = Timer.scheduledTimer(withTimeInterval: meterTick, repeats: true) { _ in
          tickMeter()
        }
      }
    } else {
      stopMeterLoop()
    }
  }

  private func stopMeterLoop() {
    meterTimer?.invalidate()
    meterTimer = nil
    meter = 0
    meterTarget = 0
    peak = 0
    peakTracker.reset()
  }

  private func tickMeter() {
    guard !reduceMotion else {
      // Reduce Motion: без envelope — метр и пик идут за целью напрямую.
      let fresh = min(max(meterTarget, 0), 1)
      meter = fresh
      peak = fresh
      ensureMeterLoopRunning()
      return
    }
    let newMeter = OverlayLevel.enveloped(current: meter, target: meterTarget, dt: meterTick)
    // Порог перерисовки на состоянии envelope замораживает спад у ~0.016 и
    // держит луп баллистики живым вечно — присваиваем всегда.
    meter = newMeter
    let newPeak = peakTracker.update(level: newMeter, dt: meterTick)
    if abs(newPeak - peak) > 0.0015 {
      peak = newPeak
    }
    ensureMeterLoopRunning()
  }

  // MARK: - Таймер записи

  /// Запускает/перезапускает секундный таймер: значение всегда пересчитывается
  /// от state.recordingStart (источник истины — момент старта записи),
  /// а не накапливается тиками.
  private func startClock() {
    clockTimer?.invalidate()
    refreshElapsedText()
    clockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
      refreshElapsedText()
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
}

/// REC-точка шапки: видна только при записи. Пульс — HIG «breathe»: мягкое
/// плавное «дыхание» scale/opacity 0.6→1.0 за ~1.6 с (reverses), резкое
/// мигание ЗАПРЕЩЕНО (Accessibility: flashing — антипаттерн). При Reduce
/// Motion — статичная точка без анимации.
private struct RECDot: View {
  @State private var pulse = false

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  var body: some View {
    Circle()
      .fill(Color.red)
      .frame(width: 8, height: 8)
      .scaleEffect(pulse ? 1.0 : 0.6)
      .opacity(pulse ? 1.0 : 0.6)
      .animation(
        reduceMotion ? nil : Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true),
        value: pulse
      )
      .onAppear {
        pulse = true
      }
  }
}

/// Анимация «обработка»: три точки, мягко пульсируют каскадом (opacity/scale).
/// Дешёвые для CPU анимации; перезапускаются при каждом появлении фазы за счёт
/// свежего @State в подвью. При Reduce Motion — статичные точки без анимации
/// (тот же контракт, что у REC-точки и VU-метра).
private struct ProcessingDots: View {
  @State private var animate = false

  private var reduceMotion: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  var body: some View {
    HStack(spacing: 7) {
      ForEach(0..<3, id: \.self) { i in
        Circle()
          .fill(Color.primary)
          .frame(width: 10, height: 10)
          .scaleEffect(reduceMotion ? 0.7 : (animate ? 1.0 : 0.35))
          .opacity(reduceMotion ? 0.7 : (animate ? 1.0 : 0.35))
          .animation(
            reduceMotion
              ? nil
              : Animation.easeInOut(duration: 0.6)
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

// MARK: - Текст ошибки для оверлея (чистый маппинг)

/// Чистый маппинг ошибки диктовки → короткий текст ошибки для оверлея.
/// Сетевые сбои показываются человечно («Нет интернета» / «Таймаут STT»)
/// вместо бесконечных точек; для всех остальных ошибок возвращается nil —
/// оверлей идёт обычным путём «Ошибка: <текст>».
public enum OverlayErrorText {
  /// Текст для оверлея, если ошибка — известный сетевой сбой; иначе nil.
  public static func text(for error: Error) -> String? {
    guard let transcribeError = error as? TranscribeError else { return nil }
    if case .network(let message) = transcribeError {
      return networkText(message)
    }
    return nil
  }

  /// Маппинг сообщения сетевой ошибки в короткий человечный текст.
  /// Неизвестные сетевые сообщения → nil (обычный путь «Ошибка: <текст>»).
  public static func networkText(_ message: String) -> String? {
    // Значения локализованы и сравнимы только через статические константы
    // (динамический результат L10n.tr нельзя использовать как case-паттерн).
    if message == Transcriber.noInternetMessage {
      return message
    }
    if message == Transcriber.sttTimeoutMessage {
      return message
    }
    return nil
  }
}

/// Чистая логика позиционирования панели: без AppKit-окна, на входе только
/// точка (каретка), экран и размер панели. Вынесена отдельно, чтобы поведение
/// «панель всегда видна, над кареткой, не вылезает за экран» покрывалось
/// юнит-тестами без создания реального окна.
public enum OverlayLayout {
  /// Мин/макс ширина компактной плашки: автоширина из fittingSize контента
  /// клампится в эти границы — плашка поверх текста не «съёживается» до
  /// голой иконки и не разъезжается на весь экран при длинной шапке.
  static let minPanelWidth: CGFloat = 180
  static let maxPanelWidth: CGFloat = 240

  /// Автоширина плашки из собственного размера контента (hostingView's
  /// fittingSize): кламп [180, 240]. Чистое преобразование — тестируется
  /// без создания окна.
  public static func clampedPanelWidth(from fittingWidth: CGFloat) -> CGFloat {
    min(max(fittingWidth, minPanelWidth), maxPanelWidth)
  }

  /// Возвращает frame панели размером `panelSize` рядом с точкой `point`
  /// внутри экрана `screen`. Координаты AppKit растут ВВЕРХ (y=0 внизу),
  /// поэтому «над точкой» — это больший y: панель пробуется НАД точкой
  /// (с отступом 12pt); если она не влезает под верхний отступ экрана —
  /// ПОД точкой с зажимом к нижнему отступу. По горизонтали frame клампится
  /// в границы экрана, так что панель никогда не пропадает за его край.
  public static func panelFrame(
    near point: CGPoint,
    inside screen: CGRect,
    panelSize: CGSize
  ) -> CGRect {
    let gap: CGFloat = 12
    let minMargin: CGFloat = 8

    let posX = point.x - panelSize.width / 2
    let posXClamped = min(
      max(posX, screen.minX + minMargin), screen.maxX - panelSize.width - minMargin)

    // Над точкой (y растёт вверх): нижний край панели на gap выше точки,
    // верхний обязан остаться внутри верхнего отступа экрана.
    let aboveY = point.y + gap
    if aboveY + panelSize.height <= screen.maxY - minMargin {
      return CGRect(x: posXClamped, y: aboveY, width: panelSize.width, height: panelSize.height)
    }
    // Нет места сверху (точка у верхней кромки) — под точкой, но не ниже
    // нижнего отступа экрана: зажим спасает на коротких экранах.
    let belowY = max(point.y - gap - panelSize.height, screen.minY + minMargin)
    return CGRect(x: posXClamped, y: belowY, width: panelSize.width, height: panelSize.height)
  }

  /// Возвращает screen-канвас для точки (координатная математика выше).
  public static func screenContaining(_ point: CGPoint) -> CGRect {
    if let screen = NSScreen.screens.first(where: {
      $0.frame.insetBy(dx: -1, dy: -1).contains(point)
    }) {
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
    if let caret, isValid(caret) {
      return caret
    }
    if isValid(mouse) {
      return mouse
    }
    return screenCenter
  }
}

public final class OverlayController: NSObject {
  /// Верхняя граница фазы «обработка» (точки): жёсткий сетевой таймаут STT
  /// + небольшой запас. Используется агентом (watchdog), чтобы анимация точек
  /// гарантированно погасла, даже если запрос зависнет ниже URLSession.
  public static let processingMaxDuration: TimeInterval = Transcriber.networkRequestTimeout + 5

  private var panel: NSPanel?
  /// SwiftUI-хост контента панели: его fittingSize задаёт автоматическую
  /// ширину плашки (кламп [180, 240], см. clampedPanelWidth).
  private var hostingView: NSHostingView<OverlayContentView>?
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

  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  deinit {
    hide()
  }

  // MARK: - Public API

  public var isVisible: Bool {
    panel?.isVisible ?? false
  }

  /// Frame панели — для тестов (проверка, что панель реально зафреймлена
  /// рядом с кареткой и не уехала за экран).
  var testPanelFrame: CGRect? {
    panel?.frame
  }

  /// Сама панель — для тестов: повторные show() не должны порождать новые
  /// окна (проверяется идентичность панели).
  var testPanel: NSPanel? {
    panel
  }

  /// Состояние оверлея — для тестов (фазы записи/обработки, время старта).
  var testState: OverlayState? {
    state
  }

  public func show() {
    // Цепочка фоллбэков: AX-каретка → мышь → центр главного экрана.
    show(at: positionedPoint())
  }

  public func show(at point: CGPoint) {
    anchorPoint = point
    ensurePanel()
    guard let panel else {
      Logger.log("overlay show: panel is nil", level: "error")
      return
    }

    // Автоширина плашки из собственного размера контента (fittingSize),
    // кламп min 180 / max 240 — компактная плашка, а не фикс 280.
    let panelWidth = OverlayLayout.clampedPanelWidth(from: hostingView?.fittingSize.width ?? 0)
    let panelHeight = desiredPanelHeight()

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

    // Тестовый раннер (NANODICTATE_TESTS=1): панель создаётся и фреймится —
    // тесты проверяют frame/фазы через состояние, но НА ЭКРАН не выводится
    // (никаких orderFront / активации NSApp) — пользователя ничем не
    // тревожим. Прод: реальный вывод окна.
    if !RuntimeEnvironment.isTestRun {
      // Рендер-усиление для фонового агента без .app-бандла: принудительная
      // активация (без перехвата фокуса — ignoringOtherApps:false) до порядка
      // фронт, чтобы WindowServer реально вывел окно поверх чужого приложения.
      NSApp.activate(ignoringOtherApps: false)
      // orderFront(nil) НЕ показывает окно из неактивного фонового агента —
      // orderFrontRegardless покажет панель без активации приложения.
      panel.orderFrontRegardless()
      panel.makeKeyAndOrderFront(nil)
      panel.orderFrontRegardless()

      // Прозрачному borderless-окну WindowServer рисует тень не сразу и
      // не всегда — после вывода на экран просим пересчитать системную
      // тень (hasShadow=true без этого может не отрендериться вовсе).
      panel.invalidateShadow()

      // Отложенная проверка того, что окно РЕАЛЬНО попало на экран
      // (CGWindowList видит только окна, показанные WindowServer'ом).
      scheduleRenderCheck()
    }

    if isDebug {
      let flags = [
        "isVisible=\(panel.isVisible)",
        "isKeyWindow=\(panel.isKeyWindow)",
        "isMainWindow=\(panel.isMainWindow)",
        "isFloatingPanel=\(panel.isFloatingPanel)",
        "worksWhenModal=\(panel.worksWhenModal)",
        "level=\(panel.level.rawValue)",
        "styleMask=\(panel.styleMask.rawValue)",
        // swiftlint:disable:next trailing_comma
        "occlusion=\(panel.occlusionState.contains(.visible) ? "visible" : "occluded")",
      ].joined(separator: " ")
      Logger.log("overlay show flags: \(flags)", level: "debug")
    }

    Logger.log(
      "overlay show at (\(point.x), \(point.y)) frame=\(NSStringFromRect(frame)) "
        + "screen=\(NSStringFromRect(screen)) visible=\(panel.isVisible)",
      level: "info"
    )
  }

  public func hide(reason: String? = nil) {
    // Логируем только если панель реально была видна: ветка «mic denied»
    // доходит до hide, не показывая панель вовсе, и логировать hide как
    // событие/ошибку там не нужно (микрофонный шум в логе).
    let wasVisible = panel?.isVisible == true
    if isDebug {
      Logger.log(
        "overlay hide" + (reason.map { " reason=\($0)" } ?? "") + " wasVisible=\(wasVisible)",
        level: "debug")
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

  /// Метка «через что идёт распознавание» («gigaam · gigaam-v3») — самый верх
  /// панели. Значение приходит от агента в момент старта диктовки
  /// (вычислено из того же resolved-провайдера, которым собран распознаватель
  /// сессии); оверлей сам конфиг не читает и ярлык не строит.
  public func setSTTLabel(_ text: String) {
    state.setSTTLabel(text)
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
  /// («0:07»), панель выше; в остальных фазах — компактная плашка.
  ///
  /// idle ~150 (компактная плашка без шапки-стринг и таймера), recording
  /// ~178 (таймер под иконкой). Ширина при смене фазы НЕ меняется — только
  /// высота (см. resizePanelForCurrentPhase). Высота НЕ зависит от наличия
  /// шапки в момент показа — setSTTLabel приходит после show() и resize не
  /// триггерит; при пустой метке появляется лишь пара лишних pt воздуха
  /// сверху, layout не скачет между сеансами.
  private func desiredPanelHeight() -> CGFloat {
    switch state.phase {
    case .recording: return 178
    case .idle, .processing: return 150
    }
  }

  /// Пересчитывает frame панели после смены фазы: высота меняется (таймер
  /// добавляет ~28pt), а панель остаётся привязана к той же точке показа.
  private func resizePanelForCurrentPhase() {
    guard let panel, let point = anchorPoint else { return }
    let screen = OverlayLayout.screenContaining(point)
    let frame = OverlayLayout.panelFrame(
      near: point,
      inside: screen,
      panelSize: CGSize(width: panel.frame.width, height: desiredPanelHeight())
    )
    panel.setFrame(frame, display: true)
    // Тень после ресайза тоже пересчитывается только по явному запросу —
    // иначе ловим рваный/застывший halo вокруг изменившейся плашки.
    panel.invalidateShadow()
  }

  // MARK: - Panel Setup

  private func ensurePanel() {
    guard panel == nil else { return }

    let panel = NSPanel(
      // Стартовый размер несуществен: show() сразу ставит реальный frame
      // из автоширины контента (кламп [180,240]) и высоты фазы. 200×150 —
      // середина клампа × компактная высота (idle).
      contentRect: NSRect(x: 0, y: 0, width: 200, height: 150),
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    // HUD-канон: системная тень остаётся включённой (hasShadow=true), но
    // у прозрачного borderless-окна WindowServer может её не отрисовать —
    // гарантированную тень рисует само SwiftUI-вью (.shadow в
    // OverlayContentView), а invalidateShadow() просит пересчитать и
    // системную после show/ресайза.
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isMovableByWindowBackground = true
    panel.allowsToolTipsWhenApplicationIsInactive = true
    panel.isReleasedWhenClosed = false
    panel.animationBehavior = .utilityWindow

    let hostingView = NSHostingView(rootView: OverlayContentView(state: state))
    guard let contentView = panel.contentView else {
      preconditionFailure("NSPanel всегда создаётся с contentView")
    }
    hostingView.frame = contentView.bounds
    hostingView.autoresizingMask = [.width, .height]
    contentView.addSubview(hostingView)

    self.hostingView = hostingView
    self.panel = panel
    if isDebug {
      Logger.log(
        "overlay panel created styleMask=\(panel.styleMask.rawValue) level=\(panel.level.rawValue)",
        level: "debug"
      )
    }
  }

  // MARK: - Accessibility Positioning

  private func caretPosition() -> CGPoint? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    let axApp = AXUIElementCreateApplication(pid)
    // Ограничиваем AX IPC: дефолтный таймаут ~6 s на вызов, зависшее
    // приложение блокирует main thread.
    AXUIElementSetMessagingTimeout(axApp, 0.25)

    var focusedElement: AnyObject?
    let focusResult = AXUIElementCopyAttributeValue(
      axApp, kAXFocusedUIElementAttribute as CFString, &focusedElement
    )
    guard focusResult == .success, let element = focusedElement else { return nil }

    // swiftlint:disable:next force_cast
    let axElement = element as! AXUIElement
    AXUIElementSetMessagingTimeout(axElement, 0.25)

    var positionValue: AnyObject?
    let posResult = AXUIElementCopyAttributeValue(
      axElement, kAXPositionAttribute as CFString, &positionValue
    )
    guard posResult == .success, let posVal = positionValue else { return nil }

    var position = CGPoint.zero
    // swiftlint:disable:next force_cast
    guard AXValueGetValue(posVal as! AXValue, .cgPoint, &position) else { return nil }

    var size = CGSize.zero
    var sizeValue: AnyObject?
    let sizeResult = AXUIElementCopyAttributeValue(
      axElement, kAXSizeAttribute as CFString, &sizeValue
    )
    if sizeResult == .success, let sizeVal = sizeValue {
      // swiftlint:disable:next force_cast
      AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)
    }

    // AX coordinates: origin at the top-left of the primary screen, y grows downward.
    // AppKit coordinates: origin at the bottom-left of the primary screen, y grows upward.
    // Caret anchor per spec: position + (width/2, 0) in AX space, then flipped to AppKit.
    // Primary = NSScreen.screens.first: AX меряет от primary, NSScreen.main на
    // secondary-мониторе дал бы неверный centerY.
    let primaryScreen = NSScreen.screens.first?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    let centerX = position.x + size.width / 2
    let centerY = primaryScreen.maxY - position.y
    return CGPoint(x: centerX, y: centerY)
  }

  // MARK: - Позиционирование с фоллбэками

  /// Проверяет, что точка лежит внутри какого-либо реального экрана
  /// (небольшой запас -1pt, чтобы точки ровно на границе не отбрасывались).
  private func isValidScreenPoint(_ point: CGPoint) -> Bool {
    NSScreen.screens.contains { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }
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
    if let caret, point == caret {
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
    // в этом случае окна нет по делу, и логировать «NO NanoDictateAgent window»
    // как ошибку не нужно.
    guard isVisible else { return }
    guard
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]]
    else {
      Logger.log("overlay render check: CGWindowListCopyWindowInfo unavailable", level: "error")
      return
    }
    let matches = windows.filter {
      ($0[kCGWindowOwnerName as String] as? String) == "NanoDictateAgent"
    }
    guard !matches.isEmpty else {
      Logger.log(
        "overlay render check: NO NanoDictateAgent window on screen after 0.5s", level: "error")
      return
    }
    for window in matches {
      let bounds = window[kCGWindowBounds as String] ?? "unknown"
      let layer = window[kCGWindowLayer as String] ?? "unknown"
      let onscreen = window[kCGWindowIsOnscreen as String] ?? "unknown"
      Logger.log(
        "overlay render check: on-screen window bounds=\(bounds) layer=\(layer) isOnscreen=\(onscreen)",
        level: "info"
      )
    }
  }

  private func screenCenter() -> CGPoint {
    guard let screen = NSScreen.main else { return CGPoint(x: 720, y: 450) }
    return CGPoint(x: screen.frame.midX, y: screen.frame.midY)
  }
}

// swiftlint:enable file_length
