import Foundation

// MARK: - InsertMethod

/// Способ вставки распознанного текста (ключ конфига `insert_method`).
public enum InsertMethod: String, Equatable {
  /// Прямая эмуляция клавиатуры CGEvent (поведение по умолчанию).
  case cgevent
  /// Через буфер обмена + Cmd+V (прежний буфер восстанавливается).
  case clipboard
}

// MARK: - AppConfig

public struct AppConfig: Equatable {  // swiftlint:disable:this type_body_length
  public var baseURL: String
  public var model: String
  public var apiKey: String
  public var apiKeyFile: String?
  public var proxyKey: String
  public var timeoutSeconds: Double
  public var doubleAltMaxInterval: Double
  public var soundsEnabled: Bool
  public var logLevel: String
  public var language: String
  public var uiLanguage: String

  /// Заголовок для передачи proxy_key (по умолчанию `X-Proxy-Key`).
  public var proxyKeyHeader: String = "X-Proxy-Key"

  /// Транспорт STT (ключ `transport`, корневой или в секции активного
  /// провайдера). Значения: `direct` (пусто) — напрямую; `http` — HTTP-прокси
  /// (`http_proxy` + опц. `proxy_user`/`proxy_password`); `gateway` — relay
  /// секрета заголовком (`proxy_key` + `proxy_key_header`); `cookie-relay` —
  /// прокси с JS-челленджем и вычисляемой `__test`-кукой в памяти.
  /// Legacy-алиасы старого конфига канонизируются в `cookie-relay`
  /// (см. `canonicalTransport`).
  public var transport: String = ""

  /// HTTP-прокси (transport == "http"): URL запроса переписывается в
  /// `<httpProxy>/<полный-исходный-URL>` (схема «URL-как-путь»). Работает
  /// только со схемой `https://` — без неё прокси игнорируется (плоский
  /// HTTP проксирует аудио и секреты открыто, CWE-319). При
  /// proxy_user/proxy_password — заголовок `Proxy-Authorization: Basic`.
  public var httpProxy: String = ""
  /// Логин HTTP-прокси (опционально; ключ `proxy_user`).
  public var proxyUser: String = ""
  /// Пароль HTTP-прокси (опционально; ключ `proxy_password`).
  public var proxyPassword: String = ""

  // MARK: Быстрые UX-победы

  /// Окно undo последней вставки (сек): двойной Alt в пределах этого окна
  /// после успешной вставки стирает вставленный текст (ключ `undo_max_interval`).
  public var undoMaxInterval: Double
  /// Играть ли звук отката вставки (ключ `undo_sound_enabled`).
  public var undoSoundEnabled: Bool

  // MARK: Пошаговая (чанковая) диктовка

  /// Пошаговая (чанковая) диктовка: сегменты → инкрементальная вставка →
  /// финальный проход по всему WAV. OFF по умолчанию — ровно текущее поведение.
  public var chunked: Bool

  // MARK: Провайдеры STT

  /// Имя активной секции `[providers.X]` (пусто — не задан: legacy-конфиг).
  public var activeProvider: String

  /// Секции `[providers.X]` в порядке их появления в конфиге.
  public var providers: [Provider]

  /// Имена секций провайдеров (id) в порядке появления.
  public var providerNames: [String] {
    providers.map(\.id)
  }

  // MARK: Маршрутизация STT по ролям

  /// Маршрутизация STT-провайдеров по ролям (секция `[routing]` конфига):
  /// `segment_provider` — сегменты пошаговой диктовки, `final_provider` —
  /// финальный проход по всей записи. Пусто — роль играет active_provider
  /// (ровно текущее поведение).
  public var routing = Routing()

  /// Маршрутизация `[routing]`: по одному id провайдера на роль.
  public struct Routing: Equatable {
    /// Провайдер сегментов пошаговой (чанковой) диктовки; пусто — активный.
    public var segmentProvider: String = ""
    /// Провайдер финального прохода по всей записи; пусто — активный.
    public var finalProvider: String = ""

    public init(segmentProvider: String = "", finalProvider: String = "") {
      self.segmentProvider = segmentProvider
      self.finalProvider = finalProvider
    }
  }

  // MARK: UX-опции (средние улучшения)

  /// Явный список провайдеров в порядке failover (топ-уровневый ключ
  /// `providers = ["groq", "gigaam"]`). Пусто — порядок секций `[providers.X]`.
  public var providersOrder: [String]

  /// Автоматический failover на следующий провайдер при сетевой/серверной
  /// ошибке основного (ключ `auto_failover`; дефолт false — прод-поведение).
  public var autoFailover: Bool

  /// Способ вставки распознанного текста (ключ `insert_method`; дефолт cgevent).
  public var insertMethod: InsertMethod

  /// Ревью перед вставкой: показать текст в stdout и ждать Enter/Esc
  /// (ключ `review_before_insert`; дефолт false — прод-поведение).
  public var reviewBeforeInsert: Bool

  // MARK: Failover-порядок

  /// Имена провайдеров в порядке failover: явный список `providers` из конфига,
  /// либо порядок появления секций `[providers.X]`.
  public var failoverOrderNames: [String] {
    providersOrder.isEmpty ? providerNames : providersOrder
  }

  /// Провайдеры для failover в порядке очереди, без уже вызванного (`failedID`).
  /// Дубли в списке схлопываются, неизвестные имена пропускаются.
  public func failoverProviders(excluding failedID: String?) -> [Provider] {
    var seen = Set<String>()
    var result: [Provider] = []
    for name in failoverOrderNames {
      guard let provider = providers.first(where: { $0.id == name }),
        seen.insert(provider.id).inserted
      else { continue }
      if provider.id == failedID {
        continue
      }
      result.append(provider)
    }
    return result
  }

  // MARK: Роли маршрутизации (резолверы)

  /// id провайдера для сегментов пошаговой диктовки (роль `segment`):
  /// `routing.segmentProvider`, если задан и есть среди секций `[providers.X]`;
  /// иначе — активный провайдер. ВНИМАНИЕ: НЕ бросает при неизвестном id
  /// (устаревшее значение роли фолбэчит на активного, а не роняет конфиг).
  public func segmentProviderID() -> String {
    routingProviderID(resolving: routing.segmentProvider)
  }

  /// id провайдера финального прохода по всей записи (роль `final`):
  /// `routing.finalProvider`, если задан и есть среди секций `[providers.X]`;
  /// иначе — активный провайдер. НЕ бросает при неизвестном id (см. выше).
  public func finalProviderID() -> String {
    routingProviderID(resolving: routing.finalProvider)
  }

  /// Общий резолвер роли: непустой id, существующий в `providers`, — сам id;
  /// пустое/неизвестное значение — фолбэк на active_provider (в legacy-конфиге
  /// он пуст — роль не задана, агент работает как раньше).
  private func routingProviderID(resolving roleID: String) -> String {
    if !roleID.isEmpty, providers.contains(where: { $0.id == roleID }) {
      return roleID
    }
    return activeProvider
  }

  // MARK: Defaults

  public static let defaults = AppConfig(
    // Личных endpoint/model по умолчанию больше нет: пустые значения,
    // адаптер известного провайдера (openai/groq/…) подставит свои
    // дефолтные baseURL/model, неизвестный id — остаётся на ручной настройке.
    baseURL: "",
    model: "",
    apiKey: "",
    apiKeyFile: nil,
    proxyKey: "",
    timeoutSeconds: 120,
    doubleAltMaxInterval: 0.4,
    soundsEnabled: true,
    logLevel: "info",
    // Язык STT-подсказки: пусто = авто-детект Whisper (языковой параметр в
    // запрос НЕ шлётся). Явное значение в конфиге (`language = "ru"`)
    // форвардится в запрос. ui_language — отдельное поле ТОЛЬКО для языка
    // меню/TUI и в STT-запрос никогда не попадает.
    language: "",
    uiLanguage: "en",
    transport: "",
    httpProxy: "",
    proxyUser: "",
    proxyPassword: "",
    undoMaxInterval: 2.0,
    undoSoundEnabled: true,
    chunked: false,
    activeProvider: "",
    providers: [],
    providersOrder: [],
    autoFailover: false,
    insertMethod: .cgevent,
    reviewBeforeInsert: false
  )

  // MARK: Public API

  public static func defaultPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return "\(home)/.config/nanodictate/config.toml"
  }

  // MARK: Example-канон (config.example.toml)

  /// Тестовый хук: переопределяет содержимое канона (nil = поиск на диске,
  /// "" — сентинел «канона нет»). В проде не используется; нужен, чтобы тесты
  /// не зависели от расположения config.example.toml и от установленной
  /// homebrew/macports-формулы на машине разработчика.
  public static var exampleContentOverride: String?

  /// Кандидаты поиска файла канона config.example.toml, первый существующий:
  /// рядом с бинарём (тарбол release.yml кладёт example в top-level рядом с
  /// бинарями), короче — в share/nanodictate (Homebrew/MacPorts), затем —
  /// ресурсы .app-бандла (Contents/Resources: resource seal — подпись не
  /// нужна, --deep verify проходит; канон перенесён из Contents/MacOS,
  /// v0.0.13), затем — фиксированные пути типовых пакетных менеджеров.
  static func bundledExampleURLs() -> [URL] {
    let executableDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
    let prefixDir = (executableDir as NSString).deletingLastPathComponent
    let prefixSharePath = "share/nanodictate/config.example.toml"
    var urls: [URL] = [
      URL(fileURLWithPath: executableDir).appendingPathComponent("config.example.toml"),
      // swiftlint:disable:next trailing_comma
      URL(fileURLWithPath: prefixDir).appendingPathComponent(prefixSharePath),
    ]
    // .app-бандл: канон лежит в Contents/Resources (resource seal — подписи не
    // требует; --deep verify проходит). У неупакованного CLI resourcePath не
    // существует (или совпадает с executableDir) — кандидат прозрачен, старый
    // порядок путей не меняется.
    if let resourcePath = Bundle.main.resourcePath {
      urls.append(
        URL(fileURLWithPath: resourcePath).appendingPathComponent("config.example.toml"))
    }
    urls.append(contentsOf: [
      URL(fileURLWithPath: "/opt/homebrew/share/nanodictate/config.example.toml"),
      URL(fileURLWithPath: "/usr/local/share/nanodictate/config.example.toml"),
      // swiftlint:disable:next trailing_comma
      URL(fileURLWithPath: "/opt/local/share/nanodictate/config.example.toml"),
    ])
    return urls
  }

  /// Содержимое канона config.example.toml: `exampleContentOverride`, если
  /// задан; иначе — первый существующий файл из `bundledExampleURLs()`.
  /// nil — канон не найден. Работает и в CLI nanodictate, и в NanoDictateAgent.
  public static func exampleContent() -> String? {
    if let override = exampleContentOverride {
      // Сентинел «канона нет»: пустая строка трактуется как отсутствие канона
      // (тесты, полагающиеся на отсутствие файла на диске, ставят "" — иначе
      // реальный поиск по bundledExampleURLs() нашёл бы установленную формулу).
      if override.isEmpty { return nil }
      return override
    }
    for url in bundledExampleURLs() {
      if let content = try? String(contentsOf: url, encoding: .utf8) {
        return content
      }
    }
    return nil
  }

  /// Load config from a TOML-like file.
  /// - If `path` is nil, uses `defaultPath()`.
  /// - If the file does not exist and the canonical `config.example.toml` is
  ///   reachable, it is copied to `path` (chmod 0600, atomic) — first launch.
  /// - If the file does not exist and the canon is not reachable, returns
  ///   default config (no error).
  /// - If the file exists but cannot be parsed, throws `AppConfigError`.
  ///
  /// Приоритет ключа: `NANODICTATE_API_KEY` (env) > `api_key` из файла >
  /// `api_key_file` из файла. Env-ключ НИКОГДА не записывается в конфиг-файл.
  public static func load(from path: String?) throws -> AppConfig {
    let resolvedPath = path ?? defaultPath()
    if !FileManager.default.fileExists(atPath: resolvedPath) {
      if let example = exampleContent() {
        // Автокопия канона при первом запуске: та же техника, что у
        // writeConfigTemplate (atomic + chmod 0600). После записи файл есть —
        // продолжаем как «файл есть».
        let dir = (resolvedPath as NSString).deletingLastPathComponent
        do {
          try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
          try Data(example.utf8).write(
            to: URL(fileURLWithPath: resolvedPath), options: .atomic)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: resolvedPath)
        } catch {
          throw AppConfigError.cannotWriteConfig(resolvedPath, error)
        }
      } else {
        // Канон недоступен — фолбэк на дефолты (без провайдера).
        return applyEnvAPIKey(to: defaults)
      }
    }
    let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
    // База мержа: канон (если доступен) поверх него накладывается юзер-файл.
    // Исключение — плоский legacy-конфиг: top-level base_url/model/api_key без
    // секций [providers.*] и без active_provider. Для него база — дефолты
    // (ровно прежнее поведение ветки «чистый legacy»); иначе секции канона
    // (6 шт.) и его active_provider "airubiz" затерли бы legacy-поля юзера
    // (включая apiKey/apiKeyFile, которые resolveActiveProvider ставит в nil).
    // Второе исключение — секции без active_provider: у канона обнуляются
    // activeProvider и providers (скалярные дефолты остаются). Иначе каноновы
    // "airubiz"/секции протекли бы в юзерский выбор: resolveActiveProvider
    // взял бы секцию канона активной (не первую объявленную юзером), а
    // undeclared-секции канона попали бы в failover.
    // Маркеры ищутся по некомментарным строкам: закомментированные
    // "# [providers.groq]" / "# active_provider = ..." legacy не ломают.
    let nonCommentLines = content.split(separator: "\n").filter {
      !$0.drop { $0 == " " || $0 == "\t" }.hasPrefix("#")
    }
    let hasProviderSections = nonCommentLines.contains { $0.contains("[providers.") }
    let hasActiveProvider = nonCommentLines.contains { $0.contains("active_provider") }
    let declaredProviderIDs = Self.declaredProviderIDs(inLines: nonCommentLines)
    let isLegacyFlat = !hasProviderSections && !hasActiveProvider
    var base: AppConfig
    if let example = exampleContent(), !isLegacyFlat {
      base = try parse(example)
      if hasProviderSections && !hasActiveProvider {
        base.activeProvider = ""
        base.providers = []
      }
    } else {
      base = defaults
    }
    var config = try parse(content, base: base)
    // Post-filter of the provider pool: the user file declared ITS OWN
    // [providers.X] sections — the pool keeps only those ids, plus the active
    // provider (picked canon section by name without redeclaring stays). Undeclared
    // canon sections (e.g. airubiz next to a user-declared groq) must NOT leak
    // into auto_failover after the active provider fails. When the file declares
    // no sections, current semantics stay: canon providers remain.
    if !declaredProviderIDs.isEmpty {
      var keep = declaredProviderIDs
      if !config.activeProvider.isEmpty {
        keep.insert(config.activeProvider)
      }
      config.providers = config.providers.filter { keep.contains($0.id) }
    }
    // Resolve apiKey from apiKeyFile if apiKey is empty
    if config.apiKey.isEmpty, let keyFile = config.apiKeyFile {
      config.apiKey = Self.readAPIKeyFile(at: keyFile)
    }
    return applyEnvAPIKey(to: config)
  }

  /// ids of `[providers.X]` sections declared in a config text — mirrors the
  /// `fileProviderIDs` set that `parseContent` registers. Header rules identical
  /// to the parser (whitespace trim, trailing-comment cut, normalizedSectionName,
  /// `providers.` prefix), so the pool post-filter in `load()` cannot drift from
  /// parse. Input lines are pre-filtered non-comment lines (as in `load`).
  private static func declaredProviderIDs(inLines lines: [Substring]) -> Set<String> {
    var ids = Set<String>()
    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard line.hasPrefix("[") else { continue }
      var headerLine = line
      if let hashIndex = line.firstIndex(of: "#") {
        headerLine = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
      }
      guard headerLine.hasSuffix("]") else { continue }
      let header = normalizedSectionName(String(headerLine.dropFirst().dropLast()))
      let providersPrefix = "providers."
      if header.hasPrefix(providersPrefix) {
        let providerID = String(header.dropFirst(providersPrefix.count))
        if !providerID.isEmpty {
          ids.insert(providerID)
        }
      }
    }
    return ids
  }

  /// Приоритет env-ключа NANODICTATE_API_KEY над ключом из файла. Применяется
  /// ТОЛЬКО к активному провайдеру (и к effective-полю) — остальные секции
  /// провайдеров (failover-кандидаты, роли маршрутизации) env не трогает:
  /// они сохраняют собственные api_key/api_key_file, а запросный путь
  /// (RetryProvider.resolveAPIKey) тоже отдаёт env только активной секции.
  /// Пустой active_provider — штатный прод-сценарий → первый провайдер по
  /// порядку (та же конвенция, что в агенте/CLI). Env-ключ никогда не
  /// записывается в файл.
  private static func applyEnvAPIKey(to config: AppConfig) -> AppConfig {
    guard let envKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"],
      !envKey.isEmpty
    else { return config }
    var result = config
    result.apiKey = envKey
    let activeID =
      result.activeProvider.isEmpty ? result.providers.first?.id : result.activeProvider
    if let activeID = activeID,
      let index = result.providers.firstIndex(where: { $0.id == activeID })
    {  // swiftlint:disable:this opening_brace
      result.providers[index].apiKey = envKey
    }
    return result
  }

  // MARK: Провайдер

  /// Секция `[providers.X]` в конфиге. `id` — имя секции.
  public struct Provider: Equatable {
    /// Имя секции: `groq` из `[providers.groq]`.
    public var id: String
    /// Отображаемое имя (ключ `name` в секции; пусто — не задан).
    public var name: String
    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var apiKeyFile: String?
    public var proxyKey: String
    /// Транспорт этой секции (ключ `transport` внутри `[providers.X]`).
    /// Пусто — берётся корневой `transport` (поведение как раньше).
    public var transport: String = ""
    /// HTTP-прокси секции (ключ `http_proxy`; пусто — корневой `httpProxy`).
    public var httpProxy: String = ""
    /// Логин HTTP-прокси секции (ключ `proxy_user`).
    public var proxyUser: String = ""
    /// Пароль HTTP-прокси секции (ключ `proxy_password`).
    public var proxyPassword: String = ""
    /// Имя заголовка для proxy_key (ключ `proxy_key_header` в секции или
    /// корневой). Пусто — берётся корневой, затем дефолт `X-Proxy-Key`.
    public var proxyKeyHeader: String = ""

    public static func withDefaults(id: String) -> Provider {
      Provider(
        id: id,
        name: "",
        baseURL: AppConfig.defaults.baseURL,
        model: AppConfig.defaults.model,
        apiKey: "",
        apiKeyFile: nil,
        proxyKey: "",
        transport: "",
        httpProxy: "",
        proxyUser: "",
        proxyPassword: "",
        proxyKeyHeader: ""
      )
    }
  }

  // MARK: Errors

  public enum AppConfigError: Error, CustomStringConvertible {
    case invalidLine(Int, String)
    case invalidValue(String, String, Int)
    case cannotReadKeyFile(String, Error?)
    /// Две секции с одним именем: `[providers.groq]` дважды.
    case duplicateProvider(String)
    /// `active_provider` указывает на отсутствующую секцию.
    case activeProviderNotFound(active: String, available: [String])
    /// Одновременно legacy-ключи и секции, но без `active_provider`.
    case ambiguousLegacyAndProviders
    case cannotWriteConfig(String, Error?)

    public var description: String {
      switch self {
      case let .invalidLine(line, text):
        return "Invalid config at line \(line): \(text)"
      case let .invalidValue(key, value, line):
        return "Invalid value for key '\(key)' at line \(line): '\(value)'"
      case let .cannotReadKeyFile(path, underlying):
        let msg = underlying?.localizedDescription ?? "unknown error"
        return "Cannot read API key file '\(path)': \(msg)"
      case .duplicateProvider(let id):
        return "Duplicate provider section: [providers.\(id)]"
      case let .activeProviderNotFound(active, available):
        let list =
          available.isEmpty ? L10n.tr("menu.noProviders") : available.joined(separator: ", ")
        return "active_provider = \"\(active)\" not found. Available providers: \(list)"
      case .ambiguousLegacyAndProviders:
        return "Ambiguous config: both legacy keys "
          + "(base_url/model/api_key...) and [providers.X] sections are "
          + "present, but active_provider is not set. Set active_provider."
      case let .cannotWriteConfig(path, underlying):
        let msg = underlying?.localizedDescription ?? "unknown error"
        return "Cannot write config '\(path)': \(msg)"
      }
    }
  }

  // MARK: - TOML-like parser

  public static func parse(
    _ content: String, base: AppConfig = AppConfig.defaults
  ) throws -> AppConfig {
    try parseContent(content, base: base, resolveProvider: true)
  }

  /// Разбор ТОЛЬКО провайдеров без резолва `active_provider`: не бросает ошибок
  /// выбора (stale active_provider, неоднозначность). Нужен меню и CLI, где
  /// сломанный выбор надо чинить, а не падать на загрузке.
  public static func parseProvidersOnly(_ content: String) throws -> (
    activeProvider: String, providers: [Provider]
  ) {
    let config = try parseContent(content, base: AppConfig.defaults, resolveProvider: false)
    return (config.activeProvider, config.providers)
  }

  /// Как `load(from:)`, но возвращает только провайдеров (без резолва) —
  /// для меню/CLI, которые должны работать даже при сломанном active_provider.
  public static func loadProvidersOnly(from path: String?) throws -> (
    activeProvider: String, providers: [Provider]
  ) {
    let resolvedPath = path ?? defaultPath()
    guard FileManager.default.fileExists(atPath: resolvedPath) else {
      return ("", [])
    }
    let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
    return try parseProvidersOnly(content)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func parseContent(
    _ content: String, base: AppConfig = AppConfig.defaults, resolveProvider: Bool
  ) throws -> AppConfig {
    var baseURL: String = base.baseURL
    var model: String = base.model
    var apiKey: String = base.apiKey
    var apiKeyFile: String? = base.apiKeyFile
    var proxyKey: String = base.proxyKey
    var timeoutSeconds: Double = base.timeoutSeconds
    var doubleAltMaxInterval: Double = base.doubleAltMaxInterval
    var soundsEnabled: Bool = base.soundsEnabled
    var logLevel: String = base.logLevel
    var language: String = base.language
    var uiLanguage: String = base.uiLanguage
    var transport: String = base.transport
    var httpProxy: String = base.httpProxy
    var proxyUser: String = base.proxyUser
    var proxyPassword: String = base.proxyPassword
    var proxyKeyHeader: String = base.proxyKeyHeader
    var undoMaxInterval: Double = base.undoMaxInterval
    var undoSoundEnabled: Bool = base.undoSoundEnabled
    var chunked: Bool = base.chunked

    var activeProvider = base.activeProvider
    var providers: [Provider] = base.providers

    // Новые UX-опции (средние улучшения): дефолт = прод-поведение.
    var providersOrder: [String] = base.providersOrder
    var autoFailover: Bool = base.autoFailover
    var insertMethod: InsertMethod = base.insertMethod
    var reviewBeforeInsert: Bool = base.reviewBeforeInsert

    // Маршрутизация STT по ролям ([routing]): пусто — роль играет активный.
    var segmentProvider = ""
    var finalProvider = ""

    // true, если на верхнем уровне встречен хотя бы один legacy-ключ STT
    // (base_url/model/api_key/api_key_file/proxy_key) — для детекта неоднозначности.
    var legacySTTKeysSeen = false
    // Имя текущей секции [providers.X] (nil — верхний уровень).
    var currentProviderID: String?
    // id секций [providers.X], объявленных В ЭТОМ контенте (не в base):
    // повторное объявление в том же контенте — ошибка дубликата, тогда как
    // перекрытие секции, пришедшей из base (канона), — штатный мерж.
    var fileProviderIDs = Set<String>()
    // true внутри непровайдерской секции ([api] и т.п.) — все ключи пропускаем,
    // чтобы они не утекали в top-level.
    var insideForeignSection = false
    // true внутри секции [routing] — ключи ролей читаем здесь, а не в top-level.
    var currentRoutingSection = false

    let lines = content.components(separatedBy: .newlines)
    for (index, rawLine) in lines.enumerated() {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      // Skip empty lines and comments
      if line.isEmpty || line.hasPrefix("#") {
        continue
      }
      // Section header: [providers.X] или любая другая секция.
      if line.hasPrefix("[") {
        // Отрезаем возможный хвостовой комментарий: "[providers.groq] # comment".
        var headerLine = line
        if let hashIndex = line.firstIndex(of: "#") {
          headerLine = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
        }
        guard headerLine.hasSuffix("]") else {
          throw AppConfigError.invalidLine(index + 1, rawLine)
        }
        var header = normalizedSectionName(String(headerLine.dropFirst().dropLast()))
        let providersPrefix = "providers."
        if header.hasPrefix(providersPrefix) {
          let providerID = String(header.dropFirst(providersPrefix.count))
          guard !providerID.isEmpty else {
            throw AppConfigError.invalidLine(index + 1, rawLine)
          }
          // Секция уже есть: объявленная в ЭТОМ контенте — дубликат; пришедшая
          // из base (канона) — юзер-файл перекрывает её (мерж-семантика).
          guard !fileProviderIDs.contains(providerID) else {
            throw AppConfigError.duplicateProvider(providerID)
          }
          if let existingIndex = providers.firstIndex(where: { $0.id == providerID }) {
            providers[existingIndex] = Provider.withDefaults(id: providerID)
          } else {
            providers.append(Provider.withDefaults(id: providerID))
          }
          fileProviderIDs.insert(providerID)
          currentProviderID = providerID
          insideForeignSection = false
          currentRoutingSection = false
        } else if header == "routing" {
          // Секция маршрутизации STT по ролям: ключи ролей читаем здесь.
          currentProviderID = nil
          insideForeignSection = false
          currentRoutingSection = true
        } else {
          // Чужая секция: ключи внутри неё игнорируем (регресс-гард).
          currentProviderID = nil
          currentRoutingSection = false
          insideForeignSection = true
        }
        continue
      }

      // Ключи внутри непровайдерских секций в top-level не читаем.
      if insideForeignSection {
        continue
      }

      guard let eqIndex = line.firstIndex(of: "=") else {
        throw AppConfigError.invalidLine(index + 1, rawLine)
      }
      let key = line[line.startIndex..<eqIndex]
        .trimmingCharacters(in: .whitespaces)
      let valuePart = line[line.index(after: eqIndex)...]
        .trimmingCharacters(in: .whitespaces)

      // Ключ внутри секции [providers.X].
      if let providerID = currentProviderID,
        let providerIndex = providers.firstIndex(where: { $0.id == providerID })
      {  // swiftlint:disable:this opening_brace
        switch key {
        case "name":
          providers[providerIndex].name = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "base_url":
          providers[providerIndex].baseURL = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "model":
          providers[providerIndex].model = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "api_key":
          providers[providerIndex].apiKey = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "api_key_file":
          providers[providerIndex].apiKeyFile = try parseStringOptional(
            valuePart, line: index + 1, rawLine: rawLine)
        case "proxy_key":
          providers[providerIndex].proxyKey = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "proxy_key_header":
          providers[providerIndex].proxyKeyHeader = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "transport":
          providers[providerIndex].transport = try Self.canonicalTransport(
            parseString(valuePart, line: index + 1, rawLine: rawLine)
          )
        case "http_proxy":
          providers[providerIndex].httpProxy = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "proxy_user":
          providers[providerIndex].proxyUser = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        case "proxy_password":
          providers[providerIndex].proxyPassword = try parseString(
            valuePart, line: index + 1, rawLine: rawLine)
        default:
          // Неизвестный ключ внутри секции — игнорируем
          break
        }
        continue
      }

      // Ключи секции [routing] (маршрутизация STT по ролям).
      if currentRoutingSection {
        switch key {
        case "segment_provider":
          segmentProvider = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        case "final_provider":
          finalProvider = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        default:
          // Неизвестный ключ внутри [routing] — игнорируем
          break
        }
        continue
      }

      switch key {
      case "base_url":
        baseURL = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        legacySTTKeysSeen = true
      case "model":
        model = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        legacySTTKeysSeen = true
      case "api_key":
        apiKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        legacySTTKeysSeen = true
      case "api_key_file":
        apiKeyFile = try parseStringOptional(valuePart, line: index + 1, rawLine: rawLine)
        legacySTTKeysSeen = true
      case "proxy_key":
        proxyKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        legacySTTKeysSeen = true
      case "proxy_key_header":
        proxyKeyHeader = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "transport":
        transport = try Self.canonicalTransport(
          parseString(valuePart, line: index + 1, rawLine: rawLine))
      case "http_proxy":
        httpProxy = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "proxy_user":
        proxyUser = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "proxy_password":
        proxyPassword = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "active_provider":
        activeProvider = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "timeout_seconds":
        timeoutSeconds = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
      case "double_alt_max_interval":
        doubleAltMaxInterval = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
      case "sounds_enabled":
        soundsEnabled = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
      case "log_level":
        logLevel = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "language":
        language = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "ui_language":
        uiLanguage = try parseString(valuePart, line: index + 1, rawLine: rawLine)
      case "undo_max_interval":
        undoMaxInterval = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
      case "undo_sound_enabled":
        undoSoundEnabled = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
      case "providers":
        providersOrder = try parseStringArray(valuePart, line: index + 1, rawLine: rawLine)
      case "auto_failover":
        autoFailover = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
      case "insert_method":
        let method = try parseString(valuePart, line: index + 1, rawLine: rawLine)
        switch method {
        case InsertMethod.cgevent.rawValue:
          insertMethod = .cgevent
        case InsertMethod.clipboard.rawValue:
          insertMethod = .clipboard
        default:
          throw AppConfigError.invalidValue(key, valuePart, index + 1)
        }
      case "review_before_insert":
        reviewBeforeInsert = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
      case "chunked":
        chunked = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
      default:
        // Unknown key — ignore
        break
      }
    }

    var config = AppConfig(
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      apiKeyFile: apiKeyFile,
      proxyKey: proxyKey,
      timeoutSeconds: timeoutSeconds,
      doubleAltMaxInterval: doubleAltMaxInterval,
      soundsEnabled: soundsEnabled,
      logLevel: logLevel,
      language: language,
      uiLanguage: uiLanguage,
      proxyKeyHeader: proxyKeyHeader,
      transport: transport,
      httpProxy: httpProxy,
      proxyUser: proxyUser,
      proxyPassword: proxyPassword,
      undoMaxInterval: undoMaxInterval,
      undoSoundEnabled: undoSoundEnabled,
      chunked: chunked,
      activeProvider: activeProvider,
      providers: providers,
      routing: Routing(segmentProvider: segmentProvider, finalProvider: finalProvider),
      providersOrder: providersOrder,
      autoFailover: autoFailover,
      insertMethod: insertMethod,
      reviewBeforeInsert: reviewBeforeInsert
    )

    if resolveProvider {
      try resolveActiveProvider(in: &config, legacySTTKeysSeen: legacySTTKeysSeen)
    }
    return config
  }

  /// Нормализованное имя секции: трим whitespace, снятие обрамляющих кавычек,
  /// трим id провайдера после `providers.` — так `[ providers.groq ]` и
  /// `[providers. groq]` оба именуют провайдера `groq`. Один нормализатор для
  /// парсера и точечной записи (иначе write не находит заголовок и дописывает
  /// дубль-секцию, а следующий parse падает с duplicateProvider).
  private static func normalizedSectionName(_ raw: String) -> String {
    var name = raw.trimmingCharacters(in: .whitespaces)
    if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
      name = String(name.dropFirst().dropLast())
    }
    let prefix = "providers."
    if name.hasPrefix(prefix) {
      return prefix + name.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
    return name
  }

  /// Правила выбора активного провайдера:
  /// - active_provider задан и существует → его поля заполняют effective-поля;
  /// - active_provider задан, но секции нет → ошибка со списком доступных;
  /// - только секции, без active_provider → первый по порядку;
  /// - legacy-ключи + секции без active_provider → ошибка «неоднозначно»;
  /// - только legacy → прежнее поведение (ничего не трогаем).
  private static func resolveActiveProvider(in config: inout AppConfig, legacySTTKeysSeen: Bool)
    throws
  {  // swiftlint:disable:this opening_brace
    if !config.activeProvider.isEmpty {
      guard let selected = config.providers.first(where: { $0.id == config.activeProvider }) else {
        throw AppConfigError.activeProviderNotFound(
          active: config.activeProvider,
          available: config.providers.map(\.id)
        )
      }
      apply(selected, to: &config)
    } else if !config.providers.isEmpty {
      if legacySTTKeysSeen {
        throw AppConfigError.ambiguousLegacyAndProviders
      }
      apply(config.providers[0], to: &config)
    }
    // else: чистый legacy-конфиг — ровно прежнее поведение.
  }

  private static func apply(_ provider: Provider, to config: inout AppConfig) {
    config.baseURL = provider.baseURL
    config.model = provider.model
    config.apiKey = provider.apiKey
    config.apiKeyFile = provider.apiKeyFile
    config.proxyKey = provider.proxyKey
    // Транспорт секции имеет приоритет над корневым. ВАЖНО: явный
    // transport = "" в секции корневой transport = "cookie-relay" НЕ отменяет —
    // пустое значение трактуется как «наследовать корневой», а не
    // «выключить». «Выключить» cookie-слой можно только не-special
    // значением (например transport = "direct"): агент распознаёт строго
    // "cookie-relay" (legacy-алиасы канонизированы при
    // парсинге) — для любого другого значения cookie-логику не поднимает.
    if !provider.transport.isEmpty {
      config.transport = provider.transport
    }
    // HTTP-прокси секции приоритетнее корневого; пустое — наследуется.
    if !provider.httpProxy.isEmpty {
      config.httpProxy = provider.httpProxy
    }
    if !provider.proxyUser.isEmpty {
      config.proxyUser = provider.proxyUser
    }
    if !provider.proxyPassword.isEmpty {
      config.proxyPassword = provider.proxyPassword
    }
    // Имя заголовка секции приоритетнее корневого; пустое — наследуется.
    if !provider.proxyKeyHeader.isEmpty {
      config.proxyKeyHeader = provider.proxyKeyHeader
    }
  }

  /// Каноническое значение транспорта: legacy-алиасы старого конфига
  /// приводятся к единому `cookie-relay` (лог-предупреждение о deprecation).
  /// Любое другое значение — как есть (обрезка пробелов).
  public static func canonicalTransport(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    switch trimmed {
    case "relay", "infinityfree":
      Logger.log("transport \"\(trimmed)\" is deprecated: use \"cookie-relay\"", level: "warn")
      return "cookie-relay"
    default:
      return trimmed
    }
  }

  // MARK: Value parsers

  private static func parseString(_ raw: String, line: Int, rawLine: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2,
      trimmed.hasPrefix("\""),
      trimmed.hasSuffix("\"")
    else {
      throw AppConfigError.invalidLine(line, rawLine)
    }
    let inner = trimmed.index(trimmed.startIndex, offsetBy: 1)
    let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
    return String(trimmed[inner..<end])
  }

  private static func parseStringOptional(_ raw: String, line: Int, rawLine: String) throws
    -> String?
  {  // swiftlint:disable:this opening_brace
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed == "\"\"" {
      return nil
    }
    return try parseString(trimmed, line: line, rawLine: rawLine)
  }

  private static func parseDouble(_ raw: String, line: Int, rawLine: String) throws -> Double {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard let value = Double(trimmed) else {
      throw AppConfigError.invalidLine(line, rawLine)
    }
    return value
  }

  private static func parseBool(_ raw: String, line: Int, rawLine: String) throws -> Bool {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if trimmed == "true" {
      return true
    }
    if trimmed == "false" {
      return false
    }
    throw AppConfigError.invalidLine(line, rawLine)
  }

  /// Разбор массива строк: `providers = ["groq", "gigaam"]`.
  /// Допускает пробелы между элементами и после запятых.
  private static func parseStringArray(_ raw: String, line: Int, rawLine: String) throws -> [String]
  {  // swiftlint:disable:this opening_brace
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
      throw AppConfigError.invalidLine(line, rawLine)
    }
    let inner = trimmed.dropFirst().dropLast()
    let result =
      inner
      .components(separatedBy: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    var values: [String] = []
    for item in result {
      try values.append(parseString(item, line: line, rawLine: rawLine))
    }
    return values
  }

  // MARK: Key file reader

  /// Shared reader for `api_key_file`: returns the first non-empty line that
  /// is not a `#` comment, stripping surrounding double quotes; "" — file
  /// missing/unreadable or no key line. Used by the legacy config path
  /// (readAPIKey callers) and by `RetryProvider.resolveAPIKey`.
  public static func readAPIKeyFile(at path: String) -> String {
    // Раскрываем "~": api_key_file = "~/.config/nanodictate/keys/..."
    let expandedPath = (path as NSString).expandingTildeInPath
    guard let data = FileManager.default.contents(atPath: expandedPath) else {
      return ""
    }
    let content = String(decoding: data, as: UTF8.self)
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }
      // Strip surrounding quotes if present
      if trimmed.count >= 2,
        trimmed.hasPrefix("\""),
        trimmed.hasSuffix("\"")
      {  // swiftlint:disable:this opening_brace
        let inner = trimmed.index(trimmed.startIndex, offsetBy: 1)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
        return String(trimmed[inner..<end])
      }
      return trimmed
    }
    return ""
  }

  // MARK: Запись ключей конфига (точечная правка, byte-preserving)

  /// Точечная правка строки `key = value` в конфиг-файле.
  /// Не сериализует весь файл — иначе потеряются комментарии. Строка ищется
  /// только на верхнем уровне (вне секций): поиск останавливается на первом
  /// заголовке секции, ключи внутри `[providers.*]` и других секций не
  /// затрагиваются. Значение в кавычках заменяется точечно (хвостовой
  /// комментарий сохраняется), без кавычек — заменяется всё после `=`. Если
  /// ключа нет — строка вставляется перед первой секцией, а при полном
  /// отсутствии секций добавляется в конец. После атомарной записи возвращает
  /// права 0600 (atomic-запись сбрасывает их на umask).
  ///
  /// `value` — готовая литеральная форма значения: `"gigaam"` для строк,
  /// `true`/`false` для bool, `2` для чисел.
  public static func writeKeyValue(key: String, value: String, to path: String) throws {
    let fileManager = FileManager.default
    var content = ""
    if fileManager.fileExists(atPath: path),
      let existing = try? String(contentsOfFile: path, encoding: .utf8)
    {  // swiftlint:disable:this opening_brace
      content = existing
    }

    writeKeyValue(key, value: value, into: &content)

    guard let data = content.data(using: .utf8) else {
      throw AppConfigError.cannotWriteConfig(path, nil)
    }
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
      throw AppConfigError.cannotWriteConfig(path, error)
    }
  }

  /// In-memory вариант `writeKeyValue(key:value:to:)` без файлового I/O:
  /// точечная правка строки `key = value` в тексте конфига. Семантика та же —
  /// ключ ищется только на верхнем уровне (вне секций), при отсутствии ключа
  /// строка вставляется перед первой секцией, а при полном отсутствии секций
  /// добавляется в конец. Не бросает исключений.
  public static func writeKeyValue(_ key: String, value: String, into text: inout String) {
    var replaced = false
    var lines = text.components(separatedBy: "\n")
    // Индекс первого заголовка секции — место вставки, если ключ не найден.
    var firstSectionIndex: Int?

    for (idx, line) in lines.enumerated() {
      guard !replaced else { break }
      let stripped = line.drop { $0 == " " || $0 == "\t" }
      // Заголовок секции, как в парсере: тримим оба конца, допускаем хвостовой комментарий.
      var headerText = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
      if let hashIndex = headerText.firstIndex(of: "#") {
        headerText = String(headerText[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if headerText.hasPrefix("["), headerText.hasSuffix("]") {
        // Первый заголовок секции: внутри секций ключ не ищем — дальше строки
        // секции. Индекс запоминаем для вставки при отсутствии ключа.
        if firstSectionIndex == nil {
          firstSectionIndex = idx
        }
        break
      }
      guard let eqIndex = stripped.firstIndex(of: "=") else { continue }
      let lineKey = stripped[stripped.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
      guard lineKey == key else { continue }
      let valueStart = stripped.index(after: eqIndex)
      let newLine: String
      if let open = line[valueStart...].firstIndex(of: "\""),
        let close = line[line.index(after: open)...].firstIndex(of: "\"")
      {  // swiftlint:disable:this opening_brace
        // Точечная замена значения в кавычках; хвост строки (комментарий) сохраняем.
        let prefix = String(line[..<open])
        let suffix = String(line[line.index(after: close)...])
        newLine = prefix + value + suffix
      } else {
        // Значение без кавычек (bool/число): заменяем всё после "=".
        let leading = String(line[..<valueStart])
        newLine = leading.trimmingCharacters(in: .whitespaces) + " " + value
      }
      lines[idx] = newLine
      replaced = true
    }

    if !replaced, let firstSectionIndex {
      // Ключа на верхнем уровне нет — вставляем непосредственно перед первым
      // заголовком секции, чтобы парсер прочитал строку как top-level.
      lines.insert("\(key) = \(value)", at: firstSectionIndex)
    }

    var result = lines.joined(separator: "\n")
    if !replaced, firstSectionIndex == nil {
      // Ключа нет и секций в файле нет — добавляем в конец.
      if !result.isEmpty, !result.hasSuffix("\n") {
        result += "\n"
      }
      result += "\(key) = \(value)\n"
    }
    text = result
  }

  /// Точечная правка ключа ВНУТРИ секции `[providers.<id>]`, byte-preserving:
  /// комментарии и не-секционные строки не трогаются. Если ключ в секции не
  /// найден — строка добавляется в конец секции; если секции нет вовсе —
  /// дописывается целиком (`[providers.<id>]\n<key> = <value>`). Атомарная
  /// запись + права 0600. Используется командой `nanodictate config set-key`.
  public static func writeProviderKeyValue(
    providerID: String,
    key: String,
    value: String,
    to path: String
  ) throws {
    try writeSectionKeyValue(section: "providers.\(providerID)", key: key, value: value, to: path)
  }

  /// Точечная правка ключа ВНУТРИ секции `[routing]` (маршрутизация STT по
  /// ролям): те же правила, что у `writeProviderKeyValue` — byte-preserving,
  /// ключ в конец секции, при отсутствии секции дописывается целиком
  /// (`[routing]\n<key> = <value>`). Атомарная запись + права 0600.
  /// Используется командой `nanodictate routing set|unset`.
  public static func writeRoutingKeyValue(key: String, value: String, to path: String) throws {
    try writeSectionKeyValue(section: "routing", key: key, value: value, to: path)
  }

  /// Общая реализация точечной правки ключа внутри секции (см. две
  /// обёртки выше): поиск заголовка `[<section>]` с учётом хвостового
  /// комментария, замена значения в кавычках (комментарий строки сохраняется)
  /// либо вставка `key = value` в конец секции / новой секцией.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func writeSectionKeyValue(
    section: String,
    key: String,
    value: String,
    to path: String
  ) throws {
    let fileManager = FileManager.default
    var content = ""
    if fileManager.fileExists(atPath: path),
      let existing = try? String(contentsOfFile: path, encoding: .utf8)
    {  // swiftlint:disable:this opening_brace
      content = existing
    }

    let sectionHeader = "[\(section)]"
    var lines = content.components(separatedBy: "\n")
    var headerIndex: Int?
    var inSection = false
    var replaced = false
    // Индекс первой строки ПОСЛЕ последней строки секции (место вставки).
    var sectionEnd = lines.count

    for (idx, line) in lines.enumerated() {
      let stripped = line.drop { $0 == " " || $0 == "\t" }
      // Заголовок секции, как в парсере: допускаем хвостовой комментарий.
      var headerText = String(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
      if let hashIndex = headerText.firstIndex(of: "#") {
        headerText = String(headerText[..<hashIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if headerText.hasPrefix("["), headerText.hasSuffix("]") {
        let name = normalizedSectionName(String(headerText.dropFirst().dropLast()))
        if name == normalizedSectionName(section) {
          inSection = true
          headerIndex = idx
          sectionEnd = idx + 1
        } else if inSection {
          // Секция кончилась — следующая секция.
          inSection = false
        }
        continue
      }
      if inSection {
        sectionEnd = idx + 1
        guard !replaced, let eqIndex = stripped.firstIndex(of: "=") else { continue }
        let lineKey = stripped[stripped.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
        guard lineKey == key else { continue }
        let valueStart = stripped.index(after: eqIndex)
        let newLine: String
        if let open = line[valueStart...].firstIndex(of: "\""),
          let close = line[line.index(after: open)...].firstIndex(of: "\"")
        {  // swiftlint:disable:this opening_brace
          // Точечная замена значения в кавычках; хвостовой комментарий сохраняем.
          let prefix = String(line[..<open])
          let suffix = String(line[line.index(after: close)...])
          newLine = prefix + value + suffix
        } else {
          let leading = String(line[..<valueStart])
          newLine = leading.trimmingCharacters(in: .whitespaces) + " " + value
        }
        lines[idx] = newLine
        replaced = true
      }
    }

    if !replaced {
      if headerIndex != nil {
        lines.insert("\(key) = \(value)", at: sectionEnd)
      } else {
        if !lines.isEmpty, !(lines.last ?? "").isEmpty {
          lines.append("")
        }
        lines.append(sectionHeader)
        lines.append("\(key) = \(value)")
      }
    }

    let result = lines.joined(separator: "\n")
    guard let data = result.data(using: .utf8) else {
      throw AppConfigError.cannotWriteConfig(path, nil)
    }
    do {
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
      throw AppConfigError.cannotWriteConfig(path, error)
    }
  }

  /// Точечная правка строки `active_provider = "…"` в конфиг-файле (путь по умолчанию).
  public static func writeActiveProvider(name: String) throws {
    try writeActiveProvider(name: name, to: defaultPath())
  }

  public static func writeActiveProvider(name: String, to path: String) throws {
    try writeKeyValue(key: "active_provider", value: "\"\(name)\"", to: path)
  }

  /// Точечная правка `review_before_insert = true|false`.
  public static func writeReviewBeforeInsert(value: Bool, to path: String? = nil) throws {
    try writeKeyValue(
      key: "review_before_insert", value: value ? "true" : "false", to: path ?? defaultPath())
  }

  // MARK: Маскировка и шаблон конфига (CLI: config show / config init)

  /// Маскировка секрета для показа в CLI: первые 4 + "***" + последние 4
  /// символа. «abcd***wxyz». Короткие/пустые ключи — просто "***".
  public static func maskSecret(_ secret: String) -> String {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8 else { return "***" }
    let head = trimmed.prefix(4)
    let tail = trimmed.suffix(4)
    return "\(head)***\(tail)"
  }
}  // swiftlint:disable:this file_length
