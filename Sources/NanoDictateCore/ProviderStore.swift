import Foundation

// MARK: - Контракт для меню (несколько STT-провайдеров)

/// Публичный срез провайдера для UI-меню. Секретов не содержит — только
/// выбор и метаданные.
public struct STTProvider: Equatable {
  public let id: String // = имя секции, например "groq"
  public let name: String // отображаемое имя (name из секции; fallback — id)
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

/// Доступ к списку STT-провайдеров и переключению активного.
/// Читает тот же config.toml, что и `AppConfig.load(from:)`. Резолва
/// `active_provider` не делает: меню должно работать даже при сломанном выборе.
public enum ProviderStore {
  /// Тестовый хук: переопределяет путь к конфигу (nil = defaultPath()).
  /// В проде не используется; нужен, чтобы тесты не трогали реальный конфиг.
  static var configPathOverride: String?

  /// Активный провайдер после последнего вызова `loadProviders()`.
  public static var activeProvider: STTProvider?

  /// Загружает все провайдеры из config.toml, выставляет `activeProvider`.
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

  /// Делает провайдера активным: валидация имени → точечная правка
  /// `active_provider` в config.toml (chmod 600) → обновление `activeProvider`.
  /// Несуществующее имя → `ProviderStoreError.unknownProvider` со списком.
  public static func setActive(providerID: String) throws {
    let (_, providers) = try AppConfig.loadProvidersOnly(from: configPathOverride)
    guard providers.contains(where: { $0.id == providerID }) else {
      throw ProviderStoreError.unknownProvider(
        providerID: providerID,
        available: providers.map(\.id)
      )
    }
    try AppConfig.writeActiveProvider(name: providerID, to: configPathOverride ?? AppConfig.defaultPath())
    _ = try loadProviders()
  }
}
