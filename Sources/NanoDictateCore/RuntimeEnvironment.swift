import Foundation

/// Глобальный признак «процесс запущен как тестовый раннер».
///
/// Тестовый раннер (Tests/NanoDictateCoreTests/main.swift) выставляет
/// NANODICTATE_TESTS=1 в самом начале процесса (setenv). Боевой агент
/// NanoDictateAgent и nanodictate эту переменную не выставляют — их поведение
/// не меняется ни на йоту.
///
/// Зачем: тест-сьют не должен вмешиваться в жизнь пользователя — реально
/// проигрывать системные звуки, выводить панель оверлея на экран или писать
/// логи в боевой ~/Library/Logs/NanoDictate/agent.log. Все эти эффекты
/// гейтятся на этом признаке.
///
/// Проверка читается каждый раз заново (не кэшируется): во-первых, чтобы
/// setenv в раннере был виден в любой момент; во-вторых, чтобы тесты могли
/// переопределить её точечно, если потребуется.
public enum RuntimeEnvironment {
  /// `true` — процесс является тестовым раннером NanoDictateCoreTests.
  public static var isTestRun: Bool {
    ProcessInfo.processInfo.environment["NANODICTATE_TESTS"] == "1"
  }
}
