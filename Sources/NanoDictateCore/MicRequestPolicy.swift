import Foundation

// MARK: - Анти-штормовый сторож TCC-запросов микрофона

/// Анти-штормовый сторож системных запросов доступа к микрофону (TCC).
///
/// Проблема: у фонового агента без бандла окно системного диалога может не
/// отобразиться вовсе, колбэк `requestAccess` не приходит, и каждый Alt+Alt
/// открывает НОВЫЙ запрос доступа. Серия повторных диалогов клинит tccd
/// (системный центр разрешений) и замораживает всю машину. После N таймаутов
/// запроса в окне 6 часов новый запрос доступа блокируется — пользователь
/// вместо диалога получает инструкцию «включите микрофон в System Settings».
///
/// Состояние персистентно (переживает перезапуск агента): файл
/// `~/Library/Application Support/NanoDictate/mic-request-state.json`
/// (путь инжектируется через init — тесты пишут во временную папку).
/// Запись атомарная, повреждённый/отсутствующий файл трактуется как свежее
/// состояние (запрос разрешён). Тип не бросает ошибок наружу: анти-шторм —
/// вспомогательный механизм, его сбой не должен ломать запись.
public struct MicRequestPolicy {

    /// Порог срабатывания сторожа: N таймаутов в окне.
    public static let maxTimeoutsInWindow = 3
    /// Окно, внутри которого считаются таймауты: 6 часов в секундах.
    public static let windowDuration: TimeInterval = 6 * 3600

    /// URL файла состояния; nil — только память (персистенция выключена).
    private let fileURL: URL?
    /// Моменты таймаутов запроса. Могут быть и старше окна — они отсеиваются
    /// при подсчёте (сброс «по времени») и не подрезаются до следующей записи.
    private var timeoutTimestamps: [Date]

    public init(fileURL: URL?) {
        self.fileURL = fileURL
        self.timeoutTimestamps = []
        if let fileURL = fileURL {
            self.timeoutTimestamps = Self.loadState(from: fileURL)
        }
    }

    /// Файл состояния по умолчанию: Application Support/NanoDictate.
    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("NanoDictate/mic-request-state.json", isDirectory: false)
    }

    /// Разрешён ли НОВЫЙ запрос доступа: таймаутов внутри текущего окна меньше
    /// порога. Сторож non-mutating: проверка сама по себе ничего не меняет.
    public func allowRequest(now: Date) -> Bool {
        timeouts(inWindow: now).count < Self.maxTimeoutsInWindow
    }

    /// Зафиксировать таймаут запроса (колбэк requestAccess не пришёл): таймаут
    /// дописывается в окно — после maxTimeoutsInWindow повторов запрос доступа
    /// блокируется (см. allowRequest). Устаревшие таймауты подрезаются, новое
    /// состояние персистится.
    public mutating func recordTimeout(now: Date) {
        timeoutTimestamps = timeouts(inWindow: now) + [now]
        persist()
    }

    /// Грант доступа получен — счётчик таймаутов сбрасывается: проблема решена,
    /// шторм больше не актуален. Состояние персистится.
    public mutating func recordGranted(now: Date) {
        timeoutTimestamps = []
        persist()
    }

    // MARK: - Private

    /// Таймауты, ещё живущие внутри окна (now - t < windowDuration).
    private func timeouts(inWindow now: Date) -> [Date] {
        timeoutTimestamps.filter { now.timeIntervalSince($0) < Self.windowDuration }
    }

    /// Загрузка состояния. Отсутствующий или повреждённый файл — свежее
    /// состояние (пустой список): мусор в файле не должен ломать сторож.
    private static func loadState(from url: URL) -> [Date] {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return []
        }
        return state.timeoutTimestamps.map { Date(timeIntervalSince1970: $0) }
    }

    /// Атомарная персистенция: каталог создаётся при необходимости, файл
    /// пишется через `.atomic` (rename — читатель видит либо старое, либо
    /// новое состояние, никогда «полузапись»). Сбой записи не роняет сторож:
    /// счётчик остаётся в памяти до следующего успешного сохранения.
    private func persist() {
        guard let fileURL = fileURL else { return }
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let state = State(timeoutTimestamps: timeoutTimestamps.map { $0.timeIntervalSince1970 })
            let data = try JSONEncoder().encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.log("mic request policy: state persist failed: \(error.localizedDescription)", level: "error")
        }
    }

    /// Формат файла состояния (JSON): моменты таймаутов в epoch-секундах.
    private struct State: Codable {
        var timeoutTimestamps: [Double]
    }
}