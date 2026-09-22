import Foundation

/// Minimal skeleton placeholder — the real NanoDictateCore implementation ships in a later PR.
public enum NanoDictateCoreStub {
  /// Fail-fast entry point: a caller that reaches unimplemented functionality in
  /// the minimal skeleton gets a loud message instead of undefined behavior.
  public static func notImplemented(_ feature: String) -> Never {
    FileHandle.standardError.write(Data("NanoDictateCore: \(feature) not implemented in minimal skeleton\n".utf8))
    exit(1)
  }
}