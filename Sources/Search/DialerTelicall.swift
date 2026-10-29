import Foundation

/// The UK number assigned to the Telicall account, separate from Numero.
enum DialerTelicall {
    static func number(_ typed: String) -> String? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ "0123456789+ ()-.".contains($0) }) else { return nil }
        let compact = text.filter { "0123456789+".contains($0) }
        guard !compact.dropFirst().contains("+"), !compact.contains("+") || compact.hasPrefix("+") else { return nil }
        let digits = compact.hasPrefix("+") ? String(compact.dropFirst()) : compact
        guard digits.count <= 15,
              digits.range(of: #"^44[1-9][0-9]{8,9}$"#, options: .regularExpression) != nil else { return nil }
        return "+" + digits
    }

    static func value(_ typed: String) -> String {
        number(typed) ?? typed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
