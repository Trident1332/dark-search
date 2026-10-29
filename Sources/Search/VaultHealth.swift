import Foundation

// A new password made here, and a look at the ones kept.
//
// The generator draws from the Mac's own randomness (SystemRandomNumberGenerator
// is the system's secure source on Apple platforms) and makes sure each kind
// of character asked for turns up at least once, since a site that insists
// on a digit refuses a password that happens to have none.
//
// The checkup reads every secret, once, when asked, and says three things
// about them: too weak, used on more than one site, and kept from a page
// sent in the clear. It holds no secret afterwards — a flag per account,
// nothing else — and nothing leaves the Mac; there is no list of breaches
// consulted, because consulting one means sending something somewhere.

extension Vault {
    // MARK: - making one

    /// What a new password is made of.
    struct Recipe: Equatable {
        var length = 20
        var digits = true
        var symbols = true
        /// No l, 1, I, O or 0: for one you'll read out or type from paper.
        var plain = true

        static let lengths: [Double] = [8, 12, 16, 20, 24, 32, 48, 64]
    }

    private static let lower = "abcdefghijklmnopqrstuvwxyz"
    private static let upper = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private static let digits = "0123456789"
    /// The ones every site takes; a password form that refuses a quote or a
    /// backslash is still common, so neither is here.
    private static let symbols = "!#$%&*+-=?@^_~"
    private static let lookalikes: Set<Character> = ["l", "1", "I", "O", "0"]

    static func generate(_ recipe: Recipe) -> String {
        func pool(_ text: String) -> [Character] {
            recipe.plain ? text.filter { !lookalikes.contains($0) } : Array(text)
        }
        var pools = [pool(lower), pool(upper)]
        if recipe.digits { pools.append(pool(digits)) }
        if recipe.symbols { pools.append(pool(symbols)) }
        let all = pools.flatMap { $0 }
        let length = max(recipe.length, pools.count)
        // One of each kind first, so each is there whatever the rest draws,
        // then the rest from the lot, then shuffled so the kinds don't lead.
        var out = pools.compactMap { $0.randomElement() }
        while out.count < length, let next = all.randomElement() { out.append(next) }
        out.shuffle()
        return String(out)
    }

    // MARK: - how good one is

    enum Strength: Equatable {
        case weak, fair, strong

        var title: String {
            switch self {
            case .weak: return "Weak"
            case .fair: return "Fair"
            case .strong: return "Strong"
            }
        }
    }

    /// A guess at how hard one is to find: the bits a search would have to
    /// cover, from its length and the kinds of characters in it, and a
    /// short list of the ones everybody tries first, which are no bits at
    /// all whatever they look like.
    static func strength(of password: String) -> (bits: Double, grade: Strength) {
        guard !password.isEmpty else { return (0, .weak) }
        if common.contains(password.lowercased()) { return (0, .weak) }
        var pool = 0
        if password.contains(where: { $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isNumber }) { pool += 10 }
        if password.contains(where: { !$0.isLetter && !$0.isNumber }) { pool += 33 }
        let bits = Double(password.count) * log2(Double(max(pool, 2)))
        let grade: Strength = password.count < 8 || bits < 40 ? .weak : bits < 64 ? .fair : .strong
        return (bits, grade)
    }

    /// Tried first by anyone trying. Short on purpose: the point is not to
    /// know every bad password, only to never call one of these anything
    /// but weak.
    private static let common: Set<String> = [
        "password", "password1", "passw0rd", "p@ssw0rd", "123456", "1234567", "12345678", "123456789",
        "1234567890", "12345", "123123", "111111", "000000", "qwerty", "qwerty123", "1q2w3e4r", "abc123",
        "letmein", "welcome", "admin", "login", "master", "hello", "iloveyou", "monkey", "dragon", "football",
        "baseball", "sunshine", "princess", "freedom", "whatever", "trustno1", "starwars", "shadow",
        "superman", "michael", "jennifer", "secret", "changeme", "default", "root", "guest", "test", "pass",
    ]

    // MARK: - the checkup

    /// What a look at an account found. One per account with something to
    /// say; the rest aren't listed.
    struct Flag: Identifiable, Equatable {
        var kept: Kept
        var weak = false
        /// How many other accounts share its password; 0 for none.
        var sharedWith = 0
        var clear = false

        var id: String { kept.id }
    }

    /// What a look at every password found.
    struct Checkup: Equatable {
        var flags: [Flag] = []
        /// How many were read.
        var checked = 0
        var at = Date()

        var weak: Int { flags.filter(\.weak).count }
        var reused: Int { flags.filter { $0.sharedWith > 0 }.count }
        var clear: Int { flags.filter(\.clear).count }
    }

    /// The look itself, given each account's password: the arithmetic, apart
    /// from the keychain so it can be checked without one.
    static func audit(_ items: [(kept: Kept, password: String)], at: Date = Date()) -> Checkup {
        var sharing: [String: Int] = [:]
        for item in items { sharing[item.password, default: 0] += 1 }
        var flags: [Flag] = []
        for item in items {
            let flag = Flag(
                kept: item.kept,
                weak: strength(of: item.password).grade == .weak,
                sharedWith: max(0, (sharing[item.password] ?? 1) - 1),
                clear: item.kept.clear
            )
            if flag.weak || flag.sharedWith > 0 || flag.clear { flags.append(flag) }
        }
        // The worst first: reused most, then weak, then in the clear, each
        // kind sorted by site within it.
        flags.sort {
            if $0.sharedWith != $1.sharedWith { return $0.sharedWith > $1.sharedWith }
            if $0.weak != $1.weak { return $0.weak }
            if $0.clear != $1.clear { return $0.clear }
            return $0.kept.host == $1.kept.host ? $0.kept.user < $1.kept.user : $0.kept.host < $1.kept.host
        }
        return Checkup(flags: flags, checked: items.count, at: at)
    }

    /// Every secret read, once, and looked at. Called off the main thread:
    /// a few hundred keychain reads take a moment.
    static func checkup(_ kept: [Kept]) -> Checkup {
        audit(kept.compactMap { item in secret(of: item).map { (kept: item, password: $0) } })
    }
}
