import Foundation

/// Chinese spans never enter the translation model: it sees stable placeholders instead.
public struct ChineseProtection {
    public let source: String
    public let masked: String
    public let spans: [(token: String, text: String)]

    public init(_ source: String) {
        self.source = source
        let expression = try! NSRegularExpression(pattern: #"\p{Han}+(?:[\p{P}\p{Zs}]*\p{Han}+)*"#)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        let prefix = "__ZH_" + UUID().uuidString.prefix(8).replacingOccurrences(of: "-", with: "")
        var spans: [(token: String, text: String)] = []
        var masked = source
        for (i, match) in matches.enumerated().reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            let token = "\(prefix)_\(i)__"
            spans.insert((token, String(source[range])), at: 0)
            if let maskedRange = Range(match.range, in: masked) { masked.replaceSubrange(maskedRange, with: token) }
        }
        self.masked = masked
        self.spans = spans
    }

    public var isChineseOnly: Bool {
        let letters = source.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        return !letters.isEmpty && letters.allSatisfy { TranslationGuard.hanCharacters(String($0)).count == 1 }
    }

    public func restore(_ translated: String) throws -> String {
        guard TranslationGuard.hanCharacters(translated).isEmpty else {
            throw LectureError.message("Переводчик добавил китайский текст вне защищённых вставок.")
        }
        var previousEnd = translated.startIndex
        for span in spans {
            guard translated.components(separatedBy: span.token).count == 2,
                  let range = translated.range(of: span.token, range: previousEnd..<translated.endIndex) else {
                throw LectureError.message("Переводчик потерял или переставил защищённую китайскую вставку.")
            }
            previousEnd = range.upperBound
        }
        var result = translated
        for span in spans { result = result.replacingOccurrences(of: span.token, with: span.text) }
        guard TranslationGuard.preservesChinese(source: source, translation: result) else {
            throw LectureError.message("Не удалось восстановить китайские иероглифы; оригинал сохранён.")
        }
        return result
    }
}
