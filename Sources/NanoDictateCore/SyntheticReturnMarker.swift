import CoreGraphics

/// Marks own synthetic Return via event field: session tap sees it only next run-loop pass,
/// when sync flag is already cleared. Field survives async delivery; tap skips routing/swallowing.
public enum SyntheticReturnMarker {
  /// Constant token ("NDTK"): applies to any synthetic Return, not one post.
  public static let token: Int64 = 0x4E44_544B

  /// Tag event as own synthetic Return (before posting).
  public static func mark(_ event: CGEvent) {
    event.setIntegerValueField(.eventSourceUserData, value: token)
  }

  /// Is event our synthetic Return (by event field)?
  public static func isOwnSyntheticReturn(_ event: CGEvent) -> Bool {
    event.getIntegerValueField(.eventSourceUserData) == token
  }
}
