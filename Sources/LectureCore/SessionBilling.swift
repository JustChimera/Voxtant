import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct USDRUBRate: Codable, Equatable, Sendable {
    public var rublesPerUSD: Double
    public var effectiveDate: String
    public var fetchedAt: Date
    public var source = "https://www.cbr.ru/scripts/XML_daily.asp"
    public init(rublesPerUSD: Double, effectiveDate: String, fetchedAt: Date = Date()) {
        self.rublesPerUSD = rublesPerUSD; self.effectiveDate = effectiveDate; self.fetchedAt = fetchedAt
    }
    public var isValid: Bool { rublesPerUSD.isFinite && rublesPerUSD > 0 && !effectiveDate.isEmpty }
    public static func parse(_ data: Data, fetchedAt: Date = Date()) throws -> USDRUBRate {
        let reader = CBRReader(); let parser = XMLParser(data: data); parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let value = reader.rate, value > 0, value.isFinite, !reader.date.isEmpty else {
            throw LectureError.message("Курс USD/RUB недоступен.")
        }
        return USDRUBRate(rublesPerUSD: value, effectiveDate: reader.date, fetchedAt: fetchedAt)
    }
    public static func fetch(session: URLSession = .shared) async throws -> USDRUBRate {
        let request = URLRequest(url: URL(string: "https://www.cbr.ru/scripts/XML_daily.asp")!, timeoutInterval: 6)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 262_144 else {
            throw LectureError.message("Курс USD/RUB недоступен.")
        }
        return try parse(data)
    }
}

private final class CBRReader: NSObject, XMLParserDelegate {
    var date = ""; var rate: Double?
    private var field = ""; private var text = ""; private var code = ""; private var nominal = ""; private var value = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        field = elementName; text = ""
        if elementName == "ValCurs" { date = attributes["Date"] ?? "" }
        if elementName == "Valute" { code = ""; nominal = ""; value = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if elementName == "CharCode" { code = cleaned }
        if elementName == "Nominal" { nominal = cleaned }
        if elementName == "Value" { value = cleaned }
        if elementName == "Valute", code == "USD", let n = Double(nominal), n > 0,
           let v = Double(value.replacingOccurrences(of: ",", with: ".")) { rate = v / n }
        text = ""
    }
}

public struct SessionCostSummary: Codable, Equatable, Sendable {
    public var reportedUSD: Double
    public var isComplete: Bool
    public var knownCostComponents: Int
    public var approximateRUB: Double?
    public var exchangeRate: USDRUBRate?
    public init(segments: [Segment], rate: USDRUBRate?) {
        var total = 0.0; var count = 0; var complete = true
        for segment in segments {
            let attempts = segment.attempts ?? []
            let costs = attempts.isEmpty ? [segment.asrCost, segment.translationCost].compactMap { $0 } : attempts.compactMap(\.cost)
            total += costs.filter { $0.isFinite && $0 >= 0 }.reduce(0, +)
            count += costs.count
            let noTranslationNeeded = segment.transcript.isEmpty && segment.status == .complete && segment.translationMode != "cancelled-by-user"
            if segment.status != .complete || segment.translationMode == "cancelled-by-user" || segment.asrCost == nil ||
               (!noTranslationNeeded && segment.translationCost == nil) || attempts.contains(where: { $0.cost == nil }) { complete = false }
        }
        reportedUSD = total; isComplete = complete; knownCostComponents = count
        exchangeRate = rate?.isValid == true ? rate : nil
        approximateRUB = exchangeRate.map { total * $0.rublesPerUSD }
    }
    public var compactLabel: String {
        guard isComplete || knownCostComponents > 0 else { return "$— · ₽—" }
        let prefix = isComplete ? "" : "от "
        let usd = String(format: "$%.5f", reportedUSD)
        let rub = approximateRUB.map { $0 > 0 && $0 < 0.01 ? "<0,01 ₽" : String(format: "%.2f ₽", $0) } ?? "₽—"
        return prefix + usd + (approximateRUB == nil ? " · " : " · ≈ ") + rub
    }
    public var explanation: String {
        var text = isComplete ? "Стоимость по данным OpenRouter." : "Известная часть стоимости OpenRouter. Некоторые запросы ещё не завершены или не вернули цену."
        if let rate = exchangeRate { text += " Рубли приблизительно: курс ЦБ \(rate.effectiveDate), 1 USD = \(String(format: "%.4f", rate.rublesPerUSD)) RUB. Это не курс списания банка." }
        else { text += " Курс USD/RUB пока недоступен." }
        return text
    }
}
