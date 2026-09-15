import Foundation
@testable import DictationCore

// MARK: - Тесты BatchTextJoiner (склейка с дедупом по границе)

final class BatchTextJoinerTests: XCTestCase {

    // MARK: boundaryDropCount

    @objc func testBoundaryLargestMatch() {
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "aa bb cc", next: "bb cc dd"), 2,
                       "берётся НАИБОЛЬШЕЕ совпадение суффикса и префикса")
    }

    @objc func testBoundarySingleWord() {
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "привет мир", next: "мир широк"), 1)
    }

    @objc func testBoundaryNoMatch() {
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "one two", next: "three four"), 0)
    }

    @objc func testBoundaryCaseInsensitive() {
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "Hello World", next: "hello WORLD foo"), 2)
    }

    @objc func testBoundaryEmptySides() {
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "", next: "word"), 0)
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "word", next: ""), 0)
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "", next: ""), 0)
    }

    @objc func testBoundaryLargerThanShortest() {
        // Совпадение не может превышать длину меньшей стороны.
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "a", next: "a b c"), 1)
    }

    // MARK: join

    @objc func testJoinDedupsAcrossChain() {
        let texts = ["aa bb cc", "bb cc", "cc dd"]
        XCTAssertEqual(BatchTextJoiner.join(texts), "aa bb cc dd",
                       "слова, продублированные оверлэпом, выбрасываются из головы следующего чанка")
    }

    @objc func testJoinSingleChainFullOverlap() {
        // Следующий чанк целиком — хвост предыдущего: ничего нового не добавляется.
        XCTAssertEqual(BatchTextJoiner.join(["apple banana", "banana"]), "apple banana")
    }

    @objc func testJoinNoOverlap() {
        XCTAssertEqual(BatchTextJoiner.join(["один два", "три четыре"]), "один два три четыре")
    }

    @objc func testJoinSingleWordSurvives() {
        XCTAssertEqual(BatchTextJoiner.join(["привет"]), "привет", "одиночное слово не теряется")
    }

    @objc func testJoinEmptyTextsSkipped() {
        XCTAssertEqual(BatchTextJoiner.join(["", "  ", "word", ""]), "word")
        XCTAssertEqual(BatchTextJoiner.join([]), "")
    }

    @objc func testJoinCollapsesWhitespace() {
        XCTAssertEqual(BatchTextJoiner.join(["a\n b", "c  d"]), "a b c d")
    }

    @objc func testJoinPunctuationInsideWord() {
        // Пунктуация внутри слова сравнивается как есть (как WordDiff.words):
        // одинаковые слова с одинаковой пунктуацией — совпадение.
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "мир, мир,", next: "мир, мир, снова"), 2)
        // Разная пунктуация у «того же» слова — совпадения нет (без слепой нормализации).
        XCTAssertEqual(BatchTextJoiner.boundaryDropCount(previous: "мир. мир.", next: "мир, мир, снова"), 0)
    }

    @objc func testJoinKeepsCapitalizationOfFirstOccurrence() {
        let texts = ["Привет Мир", "мир тесен"]
        XCTAssertEqual(BatchTextJoiner.join(texts), "Привет Мир тесен")
    }
}