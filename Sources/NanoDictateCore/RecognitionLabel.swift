import Foundation

/// STT route: direct to provider or via relay (`transport` field; empty → direct).
/// Uses same provider as Transcriber/RetryProvider — label reflects real route, not config string.
public enum STTRoute: Equatable {
  case direct
  /// Via relay named `relay` (transport = "cookie-relay").
  case relay(String)
}

/// Builds "what recognizes" label for overlay top. Pure: takes resolved values
/// actually sent to STT. Overlay never reads config — label arrives via `OverlayController.setSTTLabel`.
public enum RecognitionLabel {
  /// Route from `transport` (nil/empty → direct). Value canonicalized
  /// (legacy aliases → "cookie-relay") — label independent of stale config strings.
  public static func route(transport: String?) -> STTRoute {
    guard let transport else { return .direct }
    let trimmed = transport.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .direct }
    return .relay(AppConfig.canonicalTransport(trimmed))
  }

  /// Active session provider: `active_provider` if set (guaranteed after
  /// `AppConfig.parse`), else first `[providers.X]` section; nil — no sections (legacy).
  /// Mirrors `resolveActiveProvider` in Config.swift — label must name the
  /// provider whose fields built the Transcriber.
  public static func activeProviderID(in config: AppConfig) -> String? {
    if !config.activeProvider.isEmpty {
      return config.activeProvider
    }
    return config.providers.first?.id
  }

  /// Display name: section `name` if non-empty, else `id` — fallback keeps
  /// label bound to config, never silently missing.
  public static func displayName(for providerID: String, in config: AppConfig) -> String {
    let configured = config.providers
      .first { $0.id == providerID }?
      .name
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let configured, !configured.isEmpty else { return providerID }
    return configured
  }

  /// Session label from the resolved config that built Transcriber/relay —
  /// not re-read at overlay time, not hardcoded; resolved provider is single source of truth.
  ///
  /// - resolved: "<displayName> · <model>", via relay "<relay>→<displayName> · <model>";
  /// - empty model: provider name only (route prefix if any);
  /// - unresolved (legacy, no sections): "—".
  /// - legacy (root base_url, no sections): always "—" per spec; real server host
  ///   deliberately not shown — no provider name to display, bare host confuses.
  public static func forSession(_ config: AppConfig) -> String {
    guard let providerID = activeProviderID(in: config) else { return "—" }
    return build(
      provider: displayName(for: providerID, in: config),
      model: config.model,
      route: route(transport: config.transport)
    )
  }

  /// Label string: direct — "<provider> · <model>"; relay — "<relay>→<provider> · <model>".
  public static func build(provider: String, model: String, route: STTRoute = .direct) -> String {
    let labelParts = parts(provider: provider, model: model, route: route)
    return labelParts.model.isEmpty
      ? labelParts.provider : "\(labelParts.provider) · \(labelParts.model)"
  }

  // MARK: - Раздельные части ярлыка (шапка оверлея)

  /// Overlay header parts; rendered as two values (provider bold, model dimmed),
  /// not one glued string.
  public struct RecognitionLabelParts: Equatable {
    /// Route part: "<relay>→<provider>" (relay) or plain provider (direct); legacy — "—".
    public let provider: String
    /// Model to display; empty — hide.
    public let model: String

    public init(provider: String, model: String) {
      self.provider = provider
      self.model = model
    }
  }

  /// Parts from resolved values — same inputs as `build`/`forSession`; `build`
  /// derives from here, so string and parts can't diverge.
  public static func parts(provider: String, model: String, route: STTRoute = .direct)
    -> RecognitionLabelParts
  {  // swiftlint:disable:this opening_brace
    RecognitionLabelParts(
      provider: providerPart(provider: provider, route: route),
      model: model.trimmingCharacters(in: .whitespacesAndNewlines)
    )
  }

  /// Session parts like `forSession`, split: provider with route, model.
  /// Legacy (not resolved) → provider "—", empty model.
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

  /// Parse session label back into {provider, model}. Separator searched from
  /// end — providers/models must not contain " · ". No separator (legacy "—") →
  /// whole string as provider, empty model.
  public static func parts(fromLabel label: String) -> RecognitionLabelParts {
    let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.range(of: " · ", options: .backwards) else {
      return RecognitionLabelParts(provider: trimmed, model: "")
    }
    let provider = String(trimmed[..<separator.lowerBound])
    let model = String(trimmed[separator.upperBound...])
    return RecognitionLabelParts(provider: provider, model: model)
  }

  /// Provider name with route prefix: "<relay>→<provider>" (relay) or plain provider.
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
