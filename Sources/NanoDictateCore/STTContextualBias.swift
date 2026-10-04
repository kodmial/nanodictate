import Foundation

// MARK: - Contextual STT biasing (technical vocabulary + multi-language hints)

// Provider/model-aware contextual biasing for technical dictation:
// a reusable vocabulary list (product names, APIs, identifiers) and extra
// language hints for code-switching (e.g. Russian/English). Every feature is
// gated by the concrete model profile (STTCapabilities, see #22): unsupported
// providers/models never receive invalid API fields — the bias is folded into
// supported fields (prompt / languages[]) or dropped with a deterministic
// diagnostic for the caller to log.
//
// Current provider reality (2026-09):
// - Only the realtime `gpt-live-transcribe` family declares
//   `supportsKeywordBiasing` (dedicated `keywords` in `session.update`).
//   Batch vocabulary is therefore folded into the `prompt` field where
//   `supportsPrompt` is true.
// - `gpt-transcribe` uses multi language hints (`languages[]`); Whisper-style
//   models use a single `language` field; Cloudflare uses none.
// Adding a future model with a dedicated keywords field means flipping
// `supportsKeywordBiasing` in one STTModelRegistry entry — request builders
// follow automatically.

/// User-configurable contextual bias for one STT request.
public struct STTContextualBias: Equatable {
  /// Technical terms to bias recognition toward (identifiers, product names).
  public var vocabulary: [String]
  /// Extra expected languages besides the primary `language` hint
  /// (code-switching, e.g. `["en", "ru"]`).
  public var extraLanguages: [String]

  public init(vocabulary: [String] = [], extraLanguages: [String] = []) {
    self.vocabulary = vocabulary
    self.extraLanguages = extraLanguages
  }

  public static let none = STTContextualBias(vocabulary: [], extraLanguages: [])
}

/// Size/count limits and serialization rules for contextual bias.
public enum STTContextualBiasLimits {
  /// Maximum vocabulary terms kept after normalization.
  public static let maxTerms = 50
  /// Maximum characters per term (longer terms are truncated).
  public static let maxTermLength = 64
  /// Maximum characters for the serialized vocabulary hint inside `prompt`.
  public static let maxVocabularyChars = 400
  /// Maximum extra language hints kept after normalization.
  public static let maxExtraLanguages = 4
  /// Maximum total language hints for multi-hint profiles (primary + extras).
  public static let maxTotalLanguages = 5
  /// Maximum combined prompt length (chain context + vocabulary hint).
  public static let maxCombinedPromptLength = 1000
}

/// Result of applying contextual bias to a concrete model profile.
public struct STTAppliedBias: Equatable {
  /// Prompt to send (`nil` = omit the field). Chain context is preserved;
  /// the vocabulary hint is appended where the profile supports `prompt`.
  public var effectivePrompt: String?
  /// Languages array for multi-hint profiles (`languages[]`).
  public var effectiveLanguages: [String]
  /// Single language field for single-hint profiles.
  public var effectiveLanguage: String
  /// Dedicated keywords field for profiles with
  /// `supportsKeywordBiasing` (realtime family today; nil for batch
  /// profiles) — reserved so the gating path is covered by tests.
  public var keywordsField: [String]?
  /// True when vocabulary was configured but dropped (no prompt or keyword
  /// support on this profile).
  public var vocabularyDropped: Bool
  /// Extra languages that were configured but not sent.
  public var droppedExtraLanguages: [String]
  /// Human-readable diagnostic for dropped features (nil when nothing dropped).
  /// Callers log it at warning level instead of sending invalid API fields.
  public var diagnostic: String?

  public init(
    effectivePrompt: String? = nil,
    effectiveLanguages: [String] = [],
    effectiveLanguage: String = "",
    keywordsField: [String]? = nil,
    vocabularyDropped: Bool = false,
    droppedExtraLanguages: [String] = [],
    diagnostic: String? = nil
  ) {
    self.effectivePrompt = effectivePrompt
    self.effectiveLanguages = effectiveLanguages
    self.effectiveLanguage = effectiveLanguage
    self.keywordsField = keywordsField
    self.vocabularyDropped = vocabularyDropped
    self.droppedExtraLanguages = droppedExtraLanguages
    self.diagnostic = diagnostic
  }
}

public enum STTContextualBiasing {
  /// Sanitize one vocabulary term: trim, collapse all whitespace runs
  /// (spaces, tabs, CR/LF) to a single space so a term can never inject a
  /// multipart field boundary, drop empties, truncate to maxTermLength.
  /// Returns `nil` for terms that carry no usable text.
  public static func sanitizeTerm(_ raw: String) -> String? {
    let collapsed = raw
      .components(separatedBy: .whitespacesAndNewlines)
      .filter { !$0.isEmpty }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    guard !collapsed.isEmpty else { return nil }
    if collapsed.count <= STTContextualBiasLimits.maxTermLength {
      return collapsed
    }
    let end = collapsed.index(
      collapsed.startIndex, offsetBy: STTContextualBiasLimits.maxTermLength)
    return String(collapsed[..<end]).trimmingCharacters(in: .whitespaces)
  }

  /// Normalize a vocabulary list: sanitize, drop empties, dedupe
  /// case-insensitively (first spelling wins), cap term count, then cap the
  /// serialized size so the hint always fits the prompt budget.
  public static func normalizeVocabulary(_ terms: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for term in terms {
      guard let clean = sanitizeTerm(term) else { continue }
      let key = clean.lowercased()
      guard !key.isEmpty, !seen.contains(key) else { continue }
      seen.insert(key)
      result.append(clean)
      if result.count >= STTContextualBiasLimits.maxTerms { break }
    }
    // Enforce the serialized-size budget by dropping trailing terms.
    while !result.isEmpty
      && serializeVocabularyHint(result).count > STTContextualBiasLimits.maxVocabularyChars
    {
      result.removeLast()
    }
    return result
  }

  /// Normalize one language code: trim, lowercase, `_` -> `-`, keep only
  /// `[a-z0-9-]` codes of length 2...16. Returns `nil` when unusable.
  public static func normalizeLanguageCode(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "_", with: "-")
    guard (2...16).contains(trimmed.count) else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
    guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: allowed.inverted) == nil else {
      return nil
    }
    return trimmed
  }

  /// Normalize extra language hints: normalize codes, drop empties and
  /// duplicates (case-insensitive — normalization already lowercases), cap count.
  public static func normalizeExtraLanguages(_ languages: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for raw in languages {
      guard let code = normalizeLanguageCode(raw), !seen.contains(code) else { continue }
      seen.insert(code)
      result.append(code)
      if result.count >= STTContextualBiasLimits.maxExtraLanguages { break }
    }
    return result
  }

  /// Deterministic serialization of the vocabulary hint appended to `prompt`.
  /// Terms are joined with `", "` in normalized order; commas inside a term
  /// are preserved (the hint is human-readable biasing text, not a machine
  /// list — no unescaping is performed on the server side).
  public static func serializeVocabularyHint(_ terms: [String]) -> String {
    guard !terms.isEmpty else { return "" }
    return "Technical vocabulary: " + terms.joined(separator: ", ")
  }

  /// Apply user bias to a concrete model profile.
  ///
  /// - Parameters:
  ///   - bias: user-configured vocabulary + extra languages (raw, unnormalized).
  ///   - chainPrompt: previous-transcript context (batch chaining / stepwise
  ///     dictation). Never reordered or replaced — the vocabulary hint is
  ///     appended after it.
  ///   - primaryLanguage: configured single `language` hint (may be empty).
  ///   - capabilities: concrete model profile capabilities (#22 gating).
  ///   - adapterID/model: used only for the diagnostic string.
  public static func apply(
    bias: STTContextualBias,
    chainPrompt: String?,
    primaryLanguage: String,
    capabilities: STTCapabilities,
    adapterID: String = "",
    model: String = ""
  ) -> STTAppliedBias {
    let vocabulary = normalizeVocabulary(bias.vocabulary)
    let extras = normalizeExtraLanguages(bias.extraLanguages)
    let primary = primaryLanguage.trimmingCharacters(in: .whitespacesAndNewlines)

    // Language routing follows the profile language-hint mode.
    var effectiveLanguage = ""
    var effectiveLanguages: [String] = []
    var droppedExtras: [String] = []
    switch capabilities.languageHint {
    case .none:
      droppedExtras = extras
    case .single:
      effectiveLanguage = primary
      droppedExtras = extras
    case .multi:
      var merged: [String] = []
      var seen = Set<String>()
      let primaryCode = primary.isEmpty ? nil : normalizeLanguageCode(primary)
      if let primaryCode {
        merged.append(primaryCode)
        seen.insert(primaryCode)
      }
      for code in extras where !seen.contains(code) {
        merged.append(code)
        seen.insert(code)
        if merged.count >= STTContextualBiasLimits.maxTotalLanguages { break }
      }
      effectiveLanguages = merged
      // Extras that did not make it into the merged list (duplicates of the
      // primary collapse into it and are not reported as dropped; only codes
      // beyond the total cap are).
      droppedExtras = extras.filter { !merged.contains($0) }
      // Codes cut by the total cap are exactly those not in merged; the
      // filter above already captures them.
    }

    // Vocabulary routing: dedicated keywords field where supported,
    // otherwise fold into prompt where supported, otherwise drop.
    var effectivePrompt = chainPrompt
    var keywordsField: [String]? = nil
    var vocabularyDropped = false
    if !vocabulary.isEmpty {
      if capabilities.supportsKeywordBiasing {
        keywordsField = vocabulary
      }
      if capabilities.supportsPrompt {
        let hint = serializeVocabularyHint(vocabulary)
        if let chain = chainPrompt, !chain.isEmpty {
          var combined = chain + "\n" + hint
          if combined.count > STTContextualBiasLimits.maxCombinedPromptLength {
            // Preserve the chain context and trim only the optional hint.
            let maxHint =
              STTContextualBiasLimits.maxCombinedPromptLength - chain.count - 1
            if maxHint > 0 {
              let prefix = String(hint.prefix(maxHint))
              if let space = prefix.lastIndex(of: " ") {
                combined = chain + "\n" + String(prefix[..<space])
              } else {
                combined = chain
              }
            } else {
              combined = chain
            }
          }
          effectivePrompt = combined
        } else {
          effectivePrompt =
            hint.count > STTContextualBiasLimits.maxCombinedPromptLength
            ? String(hint.suffix(STTContextualBiasLimits.maxCombinedPromptLength))
            : hint
        }
      } else if !capabilities.supportsKeywordBiasing {
        // Chain context is never cleared here: the caller gates `prompt`
        // on `supportsPrompt`, so preserving `chainPrompt` keeps the
        // "never reordered or replaced" contract without sending anything.
        vocabularyDropped = true
      }
    }

    // Diagnostics: deterministic, no secrets (terms themselves are never
    // included — only counts, per config privacy expectations).
    var notes: [String] = []
    let target = adapterID.isEmpty && model.isEmpty ? "this model" : "\(adapterID)/\(model)"
    if vocabularyDropped {
      notes.append(
        "vocabulary (\(vocabulary.count) terms) ignored: \(target) supports neither prompt nor keyword biasing"
      )
    }
    // On `.none` profiles the primary hint is also dropped, so the diagnostic
    // must run when either `primary` or `extras` is non-empty — not only when
    // `droppedExtras` is non-empty (primary-only drops left no warning).
    let droppedPrimaryOnNone = capabilities.languageHint == .none && !primary.isEmpty
    if !droppedExtras.isEmpty || droppedPrimaryOnNone {
      switch capabilities.languageHint {
      case .none:
        notes.append(
          "language hints ignored: \(target) sends no language field"
        )
      case .single:
        notes.append(
          "extra languages (\(droppedExtras.joined(separator: ", "))) ignored: \(target) supports a single language hint only"
        )
      case .multi:
        notes.append(
          "extra languages truncated to \(STTContextualBiasLimits.maxTotalLanguages): \(target)"
        )
      }
    }
    let diagnostic = notes.isEmpty ? nil : notes.joined(separator: "; ")
    return STTAppliedBias(
      effectivePrompt: effectivePrompt,
      effectiveLanguages: effectiveLanguages,
      effectiveLanguage: effectiveLanguage,
      keywordsField: keywordsField,
      vocabularyDropped: vocabularyDropped,
      droppedExtraLanguages: droppedExtras,
      diagnostic: diagnostic
    )
  }

  /// Log the diagnostic for a dropped bias feature (warning level).
  /// Vocabulary terms are never logged — only counts and language codes.
  public static func logDiagnostic(_ applied: STTAppliedBias) {
    guard let diagnostic = applied.diagnostic else { return }
    Logger.log("STT contextual bias: \(diagnostic)", level: "warn")
  }
}
