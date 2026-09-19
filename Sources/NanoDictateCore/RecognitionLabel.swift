import Foundation

/// Маршрут STT-запроса: напрямую на провайдера или через реле (transport).
///
/// Расшифровывается из поля `transport` секции провайдера: пустое/отсутствующее
/// значение — прямой запрос; заданное значение (например `cookie-relay`) —
/// запрос идёт через этот маршрут. Значение берётся из ТОГО ЖЕ провайдера,
/// из которого агент собирает Transcriber/RetryProvider, — ярлык обязан
/// отражать фактический маршрут, а не строку из конфига.
public enum STTRoute: Equatable {
  /// Прямой запрос к провайдеру.
  case direct
  /// Запрос через реле с именем `relay` (например transport = "cookie-relay").
  case relay(String)
}

/// Построение ярлыка «через что идёт распознавание» для верхней части оверлея.
///
/// Чистая функция: принимает уже РАЗРЕШЁННЫЕ значения (провайдер, модель,
/// маршрут), которые реально уходят в STT-запрос, и возвращает строку показа.
/// Сам оверлей конфиг не читает — ярлык приходит от агента в сообщении старта
/// диктовки (`OverlayController.setSTTLabel`).
public enum RecognitionLabel {
  /// Маршрут запроса из значения `transport` (nil/пусто → прямой).
  /// Значение канонизируется (legacy-алиасы старого конфига →
  /// "cookie-relay") — ярлык не зависит от устаревших строк конфига.
  public static func route(transport: String?) -> STTRoute {
    guard let transport else { return .direct }
    let trimmed = transport.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .direct }
    return .relay(AppConfig.canonicalTransport(trimmed))
  }

  /// id активного провайдера сессии: `active_provider`, если задан (после
  /// резолва `AppConfig.parse` он гарантированно существует), иначе — первый
  /// провайдер по порядку секций `[providers.X]`; nil — секций нет вовсе
  /// (legacy-конфиг, провайдер не разрешился).
  ///
  /// Правило повторяет `resolveActiveProvider` в Config.swift: ярлык обязан
  /// называть ТОТ ЖЕ провайдер, чьи поля (baseURL/model/apiKey/transport)
  /// агент скопировал в effective-конфиг и из него собрал Transcriber.
  public static func activeProviderID(in config: AppConfig) -> String? {
    if !config.activeProvider.isEmpty {
      return config.activeProvider
    }
    return config.providers.first?.id
  }

  /// Отображаемое имя провайдера для ярлыка: `name` из его секции
  /// (`[providers.<id>]`), если задан и непуст; иначе — сам `id` (фоллбэк на
  /// id не даёт «лживой» метки: имя всегда резолвится во что-то стабильное,
  /// связанное с конфигом, а не молча пропадает).
  public static func displayName(for providerID: String, in config: AppConfig) -> String {
    let configured = config.providers
      .first { $0.id == providerID }?
      .name
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let configured, !configured.isEmpty else { return providerID }
    return configured
  }

  /// Ярлык сессии диктовки из РАЗРЕШЁННОГО конфига — того же самого, из
  /// которого агент в init собрал Transcriber и cookie-relay-слой (resolvedConfig).
  /// Конфиг в момент показа оверлея НЕ перечитывается и ярлык не хардкодится:
  /// единый источник истины — разрешённый провайдер сессии.
  ///
  /// - провайдер разрешён: `"<displayName> · <model>"` (через реле —
  ///   `"<реле>→<displayName> · <model>"`), где displayName — `name` секции
  ///   провайдера, либо id, если name пуст/отсутствует;
  /// - модель пустая: только имя провайдера (с маршрутом, если он есть);
  /// - провайдер не разрешился вовсе (legacy без секций): `"—"`.
  ///
  /// Подробнее про legacy (корневой `base_url`, секций `[providers.X]` нет):
  /// метка ВСЕГДА `"—"` — это по спеке. Реальный сервер запроса (host из
  /// корневого base_url) в ярлык НЕ выносится намеренно: legacy-конфиг не
  /// несёт имени провайдера, а показывать голый host/модель без провайдера
  /// запутывает. Оверлей остаётся без верхней строки — это ожидаемо.
  public static func forSession(_ config: AppConfig) -> String {
    guard let providerID = activeProviderID(in: config) else { return "—" }
    return build(
      provider: displayName(for: providerID, in: config),
      model: config.model,
      route: route(transport: config.transport)
    )
  }

  /// Строка ярлыка для оверлея:
  /// - прямой запрос: `"<провайдер> · <модель>"` (пустая модель — только провайдер);
  /// - через реле: `"<реле>→<провайдер> · <модель>"` (пустое имя реле — без стрелки).
  public static func build(provider: String, model: String, route: STTRoute = .direct) -> String {
    let labelParts = parts(provider: provider, model: model, route: route)
    return labelParts.model.isEmpty
      ? labelParts.provider : "\(labelParts.provider) · \(labelParts.model)"
  }

  // MARK: - Раздельные части ярлыка (шапка оверлея)

  /// Раздельные части ярлыка для шапки оверлея: провайдер (с маршрутом) и модель.
  /// Шапка рендерится из ДВУХ значений — иерархия «кто распознаёт», а не одной
  /// склеенной строки: провайдер — крупнее/ярче, модель — приглушённая.
  public struct RecognitionLabelParts: Equatable {
    /// Часть «через что идёт запрос»: `<реле>→<провайдер>` (relay) или просто
    /// провайдер (direct); для legacy без секций — "—".
    public let provider: String
    /// Модель, обрезанная по краям. Пустая — модель показывать не нужно.
    public let model: String

    public init(provider: String, model: String) {
      self.provider = provider
      self.model = model
    }
  }

  /// Части ярлыка из РАЗРЕШЁННЫХ значений — те же, что складываются в строку
  /// `build`/`forSession`: провайдер через `providerPart` (маршрут-префикс),
  /// модель обрезана. `build` строится отсюда, так что строка и части не могут
  /// разойтись.
  public static func parts(provider: String, model: String, route: STTRoute = .direct)
    -> RecognitionLabelParts
  {  // swiftlint:disable:this opening_brace
    RecognitionLabelParts(
      provider: providerPart(provider: provider, route: route),
      model: model.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Части ярлыка сессии из РАЗРЕШЁННОГО конфига — аналог `forSession`, но
  /// раздельно: провайдер с маршрутом (displayName из конфига, фоллбэк на id)
  /// и модель. Legacy без секций (провайдер не разрешился) → провайдер "—",
  /// модель пустая (по спеке `forSession`).
  public static func sessionParts(_ config: AppConfig) -> RecognitionLabelParts {
    guard let providerID = activeProviderID(in: config) else {
      return RecognitionLabelParts(provider: "—", model: "")
    }
    return parts(
      provider: displayName(for: providerID, in: config),
      model: config.model,
      route: route(transport: config.transport)
    )
  }

  /// Разбор строки ярлыка сессии обратно на {provider, model} для раздельного
  /// рендера шапки. Строка всегда построена как `"<provider> · <model>"`
  /// (`build`/`forSession`); разделитель ищется с конца — поставщики и модели
  /// не должны содержать " · " сами. Строка без разделителя (например legacy
  /// "—") целиком уходит в provider, модель пустая.
  public static func parts(fromLabel label: String) -> RecognitionLabelParts {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.range(of: " · ", options: .backwards) else {
      return RecognitionLabelParts(provider: trimmed, model: "")
    }
    let provider = String(trimmed[..<separator.lowerBound])
    let model = String(trimmed[separator.upperBound...])
    return RecognitionLabelParts(provider: provider, model: model)
  }

  /// Часть «через что идёт запрос»: имя провайдера с префиксом маршрута
  /// (`"<реле>→<провайдер>"` для relay, иначе — просто провайдер).
  public static func providerPart(provider: String, route: STTRoute) -> String {
    switch route {
    case .direct:
      return provider
    case .relay(let relay) where relay.isEmpty:
      return provider
    case .relay(let relay):
      return "\(relay)→\(provider)"
    }
  }
}
