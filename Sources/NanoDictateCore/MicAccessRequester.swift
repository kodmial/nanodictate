import AVFoundation
import Foundation

// MARK: - Координатор запроса доступа к микрофону (TCC)

/// Запрос системного доступа к микрофону с тремя защитами от «просит разрешение
/// → вылетает сообщение → зависает»:
/// 1) повторный запрос, пока системный диалог уже висит, не открывается
///    (`isInFlight`) — второй диалог не плодится;
/// 2) сторож `timeout`: если колбэк `requestAccess` не пришёл (у фонового агента
///    без бандла окно TCC может не отобразиться) — терминальный исход вместо
///    вечного ожидания;
/// 3) анти-шторм `MicRequestPolicy`: после N таймаутов в окне 6 ч новый запрос
///    не открывается вовсе (серия диалогов клинит tccd и морозит систему) —
///    вместо запроса клиент показывает инструкцию.
///
/// Сессионный токен (`session`) аннулирует устаревшие колбэки: сторож
/// инкрементирует его СРАЗУ при срабатывании, поэтому поздний `granted`
/// (диалог ответил уже после таймаута) не начинает запись из-под показанной
/// ошибки и не сбрасывает штормовой счётчик. Смена токена делает то же самое
/// для колбэка предыдущего запроса, когда пользователь нажал хоткей повторно.
///
/// Логики UI/логов здесь нет намеренно: модуль возвращает исход, клиент решает,
/// что показать. Вынесен из Agent в Core, чтобы поведение сторожа при позднем
/// granted покрывалось мини-XCTest (без аудио-железа и TCC).
public final class MicAccessRequester {
  /// Исход запроса — что клиент должен сделать.
  public enum Outcome: Equatable {
    /// Доступ есть (был выдан ранее или выдан сейчас) — можно начинать запись.
    case granted
    /// Доступ запрещён/ограничен — запись невозможна, нужен «System Settings».
    case denied
    /// Колбэк запроса не пришёл за `timeout`; таймаут учтён в политике.
    case timedOut
    /// Анти-шторм: запрос не открывался вовсе (исчерпан лимит таймаутов).
    case suppressedByPolicy
  }

  /// Текущий статус доступа (в проде — AVCaptureDevice.authorizationStatus).
  public typealias StatusProvider = () -> AVAuthorizationStatus
  /// Системный запрос доступа (в проде — AVCaptureDevice.requestAccess).
  /// Колбэк вызывается на произвольной очереди и здесь же переводится на
  /// главную.
  public typealias RequestAccess = (@escaping (Bool) -> Void) -> Void

  private let status: StatusProvider
  private let requestAccess: RequestAccess
  /// `var`, а не `let`: recordTimeout/recordGranted — мутирующие методы политики.
  private var policy: MicRequestPolicy
  private let timeout: TimeInterval

  /// Сессионный токен запроса: инкрементируется при каждом запросе, при
  /// срабатывании сторожа и при получении ответа — устаревшие колбэки
  /// отбрасываются по расхождению токенов.
  private var session = 0
  /// Системный диалог уже висит: повторный вызов не открывает второй.
  private var inFlight = false

  public init(
    status: @escaping StatusProvider,
    requestAccess: @escaping RequestAccess,
    policy: MicRequestPolicy,
    timeout: TimeInterval
  ) {
    self.status = status
    self.requestAccess = requestAccess
    self.policy = policy
    self.timeout = timeout
  }

  /// Системный запрос доступа сейчас в полёте (диалог показан, ответа нет).
  /// Вызывающий поток может отличить «запрос уже идёт» от «начали новый».
  public var isInFlight: Bool {
    inFlight
  }

  /// Полный цикл «проверить статус → при необходимости запросить доступ →
  /// дождаться ответа со сторожем». `completion` вызывается РОВНО ОДИН раз:
  /// либо синхронно (статус уже известен — `granted`/`denied`), либо на главной
  /// очереди (ответ системы / таймаут / сработавший анти-шторм).
  /// Повторный вызов, пока ответа ещё нет, не даёт ни исхода, ни запроса.
  public func requestIfNeeded(completion: @escaping (Outcome) -> Void) {
    switch status() {
    case .authorized:
      completion(.granted)
    case .denied, .restricted:
      completion(.denied)
    case .notDetermined:
      guard !inFlight else { return }
      guard policy.allowRequest(now: Date()) else {
        completion(.suppressedByPolicy)
        return
      }
      inFlight = true
      session += 1
      let requestSession = session

      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        // Сторож срабатывает, только пока запрос РЕАЛЬНО в полёте:
        // ответ уже снял флаг и сменил токен — иначе сторож выстреливал
        // бы посреди записи, со звуком ошибки и гашением оверлея.
        // swiftformat:disable indent
        // (индент guard-условий: swiftformat выравнивает продолжения на +6,
        // SwiftLint Kodeco разрешает максимум +2 — выравниваем под SwiftLint)
        guard let self,
          self.session == requestSession,
          self.inFlight
        else { return }
        // swiftformat:enable indent
        self.inFlight = false
        // Токен меняется ЗДЕСЬ: поздний granted (диалог ответил после
        // таймаута) увидит расхождение и будет отброшен — запись не
        // начнётся из-под уже показанной ошибки.
        self.session += 1
        // Таймаут — штормовой счётчик (окно 6 ч), см. MicRequestPolicy.
        self.policy.recordTimeout(now: Date())
        completion(.timedOut)
      }

      requestAccess { [weak self] granted in
        DispatchQueue.main.async {
          guard let self, self.session == requestSession else { return }
          self.inFlight = false
          // Смена токена аннулирует запланированный сторож (no-op).
          self.session += 1
          if granted {
            // Ответ получен — штормовой счётчик сбрасывается.
            self.policy.recordGranted(now: Date())
            completion(.granted)
          } else {
            completion(.denied)
          }
        }
      }
    @unknown default:
      completion(.denied)
    }
  }
}
