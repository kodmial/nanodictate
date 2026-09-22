import Foundation

// MARK: - Контракт для меню (несколько STT-провайдеров)

/// Provider view for UI menu; no secrets, just selection + metadata.
public struct STTProvider: Equatable {
  public let id: String  // = config section name, e.g. "groq"
  public let name: String  // display name from section; fallback — id
  public let baseURL: String
  public let model: String
  public let isActive: Bool

  public init(id: String, name: String, baseURL: String, model: String, isActive: Bool) {
    self.id = id
    self.name = name
    self.baseURL = baseURL
    self.model = model
    self.isActive = isActive
  }
}

public enum ProviderStoreError: Error, CustomStringConvertible {
  case unknownProvider(providerID: String, available: [String])

  public var description: String {
    switch self {
    case let .unknownProvider(id, available):
      let list = available.isEmpty ? L10n.tr("menu.noProviders") : available.joined(separator: ", ")
      return "Provider '\(id)' not found. Available: \(list)"
    }
  }
}

/// Provider list + active switch; reads same config.toml as AppConfig.
/// Doesn't resolve active_provider — menu works even with broken selection.
public enum ProviderStore {
  /// Test hook: override config path (nil = defaultPath()); keeps tests off real config.
  static var configPathOverride: String?

  /// Active provider from last `loadProviders()`.
  public static var activeProvider: STTProvider?

  /// Load all providers from config.toml; set `activeProvider`.
  public static func loadProviders() throws -> [STTProvider] {
    let (activeID, providers) = try AppConfig.loadProvidersOnly(from: configPathOverride)
    let list = providers.map { provider -> STTProvider in
      STTProvider(
        id: provider.id,
        name: provider.name.isEmpty ? provider.id : provider.name,
        baseURL: provider.baseURL,
        model: provider.model,
        isActive: provider.id == activeID
      )
    }
    activeProvider = list.first { $0.isActive }
    return list
  }

  /// Validate name → patch active_provider (chmod 600) → refresh activeProvider.
  /// Unknown name → ProviderStoreError.unknownProvider with available list.
  public static func setActive(providerID: String) throws {
    let (_, providers) = try AppConfig.loadProvidersOnly(from: configPathOverride)
    guard providers.contains(where: { $0.id == providerID }) else {
      throw ProviderStoreError.unknownProvider(
        providerID: providerID,
        available: providers.map(\.id)
      )
    }
    try AppConfig.writeActiveProvider(
      name: providerID, to: configPathOverride ?? AppConfig.defaultPath())
    _ = try loadProviders()
  }
}
