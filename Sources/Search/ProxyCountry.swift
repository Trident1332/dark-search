import Foundation

/// Country information comes from the existing proxy test response. Never
/// infer a country or perform another lookup when the response has none.
enum ProxyCountry {
    private static let recognized = Set(Locale.Region.isoRegions.map(\.identifier))

    static func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count == 2,
              trimmed.unicodeScalars.allSatisfy({ (65...90).contains($0.value) || (97...122).contains($0.value) }) else { return nil }
        let code = trimmed.uppercased()
        guard code != "ZZ", recognized.contains(code) else { return nil }
        return code
    }

    static func flag(for raw: String?) -> String? {
        guard let code = normalized(raw) else { return nil }
        var flag = ""
        for scalar in code.unicodeScalars {
            flag.unicodeScalars.append(UnicodeScalar(0x1F1E6 + scalar.value - 65)!)
        }
        return flag
    }
}
