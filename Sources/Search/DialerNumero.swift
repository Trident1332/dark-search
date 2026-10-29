import Foundation

/// The two owned Numero lines. A line's country is a user-assigned label:
/// US and Canadian numbers share +1, including toll-free numbering ranges.
enum DialerNumero: String, CaseIterable {
    case us, ca

    var title: String { self == .us ? "US" : "Canada" }

    /// Accept ordinary pasted formatting, but never an extension, URI,
    /// control character or other text that could enter SIP signaling.
    static func number(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ "0123456789+ ()-.".contains($0) }) else { return nil }
        let compact = text.filter { "0123456789+".contains($0) }
        guard !compact.dropFirst().contains("+"), !compact.contains("+") || compact.hasPrefix("+") else { return nil }
        var digits = compact.hasPrefix("+") ? String(compact.dropFirst()) : compact
        if digits.count == 10, !compact.hasPrefix("+") { digits = "1" + digits }
        guard digits.range(of: #"^1[2-9][0-9]{2}[2-9][0-9]{6}$"#, options: .regularExpression) != nil else { return nil }
        return "+" + digits
    }

    static func value(_ typed: String) -> String {
        number(typed) ?? typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
