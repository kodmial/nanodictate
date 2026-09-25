import AVFoundation
import Foundation

// MARK: - Координатор запроса доступа к микрофону (TCC)

/// Microphone access request, guarded against ask → dialog → hang loop:
/// 1) no second request while a dialog is up (isInFlight) — no duplicated dialog;
/// 2) timeout watchdog: bundle-less background agent's TCC window may never
///    show and callback may never come — terminal outcome instead of infinite
///    wait; the guard stays up until the system request resolves (only its
///    callback releases it), so a retry cannot pile a second dialog onto an
///    unresolved one;
/// 3) MicRequestPolicy anti-storm: N timeouts in 6h stop new requests (dialog
///    storm jams tccd, freezes system); client shows instructions instead.
/// Session token (session) invalidates stale callbacks: watchdog bumps it
/// immediately, so a late "granted" can't start recording under a shown error
/// or reset the storm counter. Token change does same for previous request's
/// callback when user pressed hotkey again.
/// No UI/logging here deliberately: module returns outcome, client decides what
/// to show. Moved from Agent to Core so late-granted watchdog behavior is
/// XCTest-coverable (no audio hardware, no TCC).
public final class MicAccessRequester {
  /// Request outcome — what the client must do.
  public enum Outcome: Equatable {
    /// Access granted (now or earlier) — recording may start.
    case granted
    /// Denied/restricted — recording impossible, needs "System Settings".
    case denied
    /// No callback within `timeout`; timeout counted in policy.
    case timedOut
    /// Anti-storm: no request opened (timeout limit exhausted).
    case suppressedByPolicy
  }

  /// Current access status (prod: AVCaptureDevice.authorizationStatus).
  public typealias StatusProvider = () -> AVAuthorizationStatus
  /// System access request (prod: AVCaptureDevice.requestAccess).
  /// Callback on arbitrary queue; forwarded to main here.
  public typealias RequestAccess = (@escaping (Bool) -> Void) -> Void

  private let status: StatusProvider
  private let requestAccess: RequestAccess
  /// `var` not `let`: policy methods are mutating.
  private var policy: MicRequestPolicy
  private let timeout: TimeInterval

  /// Session token: bumped on each request, watchdog fire, answer — stale
  /// callbacks dropped by token mismatch.
  private var session = 0
  /// System dialog already up: repeat call opens no second.
  private var inFlight = false
  /// System `requestAccess` outstanding, its callback unprocessed. Cleared
  /// ONLY in that callback (stale callbacks included). While set, the
  /// watchdog keeps `inFlight` up, so a retry cannot open a second system
  /// request on top of an unresolved one (dialog storm).
  private var systemRequestPending = false
  /// The watchdog already reported `.timedOut` for the still-pending system request.
  private var pendingTimedOut = false

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

  /// System access request currently in flight (dialog shown, no answer).
  /// Caller distinguishes "already requesting" from "started new".
  public var isInFlight: Bool {
    inFlight
  }

  /// Full cycle: check status → request if needed → wait for answer with
  /// watchdog. `completion` called EXACTLY once: synchronously (status known —
  /// granted/denied) or on main queue (answer / timeout / anti-storm).
  /// Re-call while unanswered yields neither outcome nor request.
  public func requestIfNeeded(completion: @escaping (Outcome) -> Void) {
    switch status() {
    case .authorized:
      completion(.granted)
    case .denied, .restricted:
      completion(.denied)
    case .notDetermined:
      guard !inFlight else {
        if pendingTimedOut { completion(.suppressedByPolicy) }
        return
      }
      guard policy.allowRequest(now: Date()) else {
        completion(.suppressedByPolicy)
        return
      }
      inFlight = true
      // System request is about to be issued: mark it pending. Only the
      // requestAccess callback may clear this (and, with it, inFlight).
      systemRequestPending = true
      session += 1
      let requestSession = session

      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
        // Watchdog fires only while request still in flight — an answer
        // already cleared the flag, else it would fire mid-recording
        // with error sound and overlay dismissal.
        // swiftformat:disable indent
        // (guard-cond indent: swiftformat aligns +6, SwiftLint Kodeco caps +2 — follow SwiftLint)
        guard let self,
          self.session == requestSession,
          self.inFlight
        else { return }
        // swiftformat:enable indent
        // Watchdog firing implies the system callback is still pending (only
        // a callback resolves this cycle — an answer has cleared the flags
        // and bumped the token). So `inFlight` is NOT reset while the system
        // request is unresolved: resetting it here would let a retry call
        // requestAccess again on top of the pending dialog — a dialog storm.
        // The pending callback releases the coordinator (clears both flags,
        // drops its stale outcome) when the system finally answers.
        // Bump token here: late granted (dialog answered after timeout)
        // sees mismatch and is dropped — recording won't start under a
        // shown error.
        self.session += 1
        self.pendingTimedOut = true
        // Timeout → storm counter (6h window), see MicRequestPolicy.
        self.policy.recordTimeout(now: Date())
        completion(.timedOut)
      }

      requestAccess { [weak self] granted in
        DispatchQueue.main.async {
          guard let self else { return }
          // The system answered — this is the ONLY place systemRequestPending
          // is cleared, stale callbacks included: the system request is
          // resolved regardless of our token bookkeeping, and the watchdog
          // kept inFlight up precisely until here.
          self.systemRequestPending = false
          self.pendingTimedOut = false
          guard self.session == requestSession else {
            // Stale: watchdog already timed out (or a newer cycle won the
            // token). No outcome — late granted can't start recording under
            // a shown error. No newer cycle can own inFlight while ours was
            // pending (the watchdog keeps it set), so release it here.
            self.inFlight = false
            return
          }
          self.inFlight = false
          // Token change cancels scheduled watchdog (no-op).
          self.session += 1
          if granted {
            // Answer received — reset storm counter.
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
