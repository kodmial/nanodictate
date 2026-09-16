import Foundation

// MARK: - ReviewGate
//
// Ревью распознанного текста ПЕРЕД вставкой (ключ конфига
// `review_before_insert = true`). Текст НЕ вставляется сразу: печатается в stdout
// с предложением «Вставить [Enter] / Отменить [Esc]». Enter (или пустой ввод) —
// вставка, всё остальное/Esc — отмена.
//
// Режим рассчитан на запуск агента из терминала (локальная разработка): под
// launchd/overlay stdout нет, поэтому по умолчанию (false) поведение — прежнее,
// текст вставляется сразу.

public enum ReviewGate {

    /// Решение пользователя.
    public enum Decision: Equatable {
        case insert
        case cancel
    }

    /// Ввод строки; инжектится в тестах. Дефолт — readLine().
    public static var readLineFunction: () -> String? = { readLine() }

    /// Показать текст и дождаться решения.
    /// - Enter/пустой ввод/«y»/«Y» → .insert
    /// - любое другое (в т.ч. Esc через escape-последовательность) → .cancel
    public static func confirm(text: String) -> Decision {
        print("\(L10n.tr("review.prompt")): \(text)")
        print(L10n.tr("review.confirmInsert"), terminator: " ")
        fflush(stdout)
        guard let input = readLineFunction() else { return .cancel }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "y" || trimmed == "Y" {
            return .insert
        }
        return .cancel
    }
}