import XCTest
@testable import Search

/// The pure parts of the Passwords page's lock and its tools: how long an
/// open spell lasts, how a password and its note share one keychain value,
/// what the generator makes, how a password is graded, and what the checkup
/// says. Nothing here touches the keychain or asks the Mac who you are.
final class VaultLockTests: XCTestCase {
    // MARK: - the spell

    func testASpellEndsWhenItsTimeIsUp() {
        let start = Date(timeIntervalSince1970: 1_000)
        let spell = VaultSession(opened: start, lockAfter: 300)
        XCTAssertEqual(spell.until, start.addingTimeInterval(300))
        XCTAssertFalse(spell.locked(at: start.addingTimeInterval(299)))
        XCTAssertTrue(spell.locked(at: start.addingTimeInterval(300)))
    }

    func testAUseStartsTheClockAgain() {
        let start = Date(timeIntervalSince1970: 1_000)
        var spell = VaultSession(opened: start, lockAfter: 300)
        spell.extend(at: start.addingTimeInterval(200))
        XCTAssertEqual(spell.until, start.addingTimeInterval(500))
        XCTAssertFalse(spell.locked(at: start.addingTimeInterval(400)))
        XCTAssertEqual(spell.opened, start, "when it opened doesn't move")
    }

    func testAClockPutBackDoesNotShortenTheSpell() {
        let start = Date(timeIntervalSince1970: 1_000)
        var spell = VaultSession(opened: start, lockAfter: 300)
        spell.extend(at: start.addingTimeInterval(200))
        spell.extend(at: start.addingTimeInterval(-500))
        XCTAssertEqual(spell.until, start.addingTimeInterval(500))
    }

    func testEveryLockAfterChoiceHasAName() {
        for choice in VaultLockAfter.allCases {
            XCTAssertFalse(choice.title.isEmpty)
            XCTAssertFalse(choice.spoken.isEmpty)
            XCTAssertEqual(choice.interval, TimeInterval(choice.rawValue))
        }
        XCTAssertNil(VaultLockAfter(rawValue: 7), "only the listed lengths")
    }

    // MARK: - a password and its note as one value

    func testAPasswordAloneIsKeptAsItAlwaysWas() throws {
        let packed = try XCTUnwrap(Secret(password: "hunter2").packed)
        XCTAssertEqual(String(data: packed, encoding: .utf8), "hunter2")
        XCTAssertEqual(Secret(packed), Secret(password: "hunter2"))
    }

    func testANoteRidesWithThePasswordAndComesBack() throws {
        let secret = Secret(password: "k7#Vq2Rb!xT9", notes: "Two-factor is on the blue key.\nSpare in the safe.")
        let packed = try XCTUnwrap(secret.packed)
        XCTAssertEqual(packed.first, 0, "starts with a byte no password can hold")
        XCTAssertEqual(Secret(packed), secret)
    }

    func testAnOldValueThatHappensToLookLikeJSONIsStillAPassword() {
        let data = Data("{\"p\":\"not really\"}".utf8)
        XCTAssertEqual(Secret(data), Secret(password: "{\"p\":\"not really\"}"))
    }

    func testAMarkedValueThatIsNotOursIsRefused() {
        let data = Data([0]) + Data("SV1garbage".utf8)
        XCTAssertNil(Secret(data))
    }

    // MARK: - making one

    func testAGeneratedPasswordIsAsLongAsAskedAndOfEveryKind() {
        let recipe = Vault.Recipe(length: 20, digits: true, symbols: true, plain: false)
        for _ in 0..<50 {
            let made = Vault.generate(recipe)
            XCTAssertEqual(made.count, 20)
            XCTAssertTrue(made.contains(where: { $0.isLowercase }))
            XCTAssertTrue(made.contains(where: { $0.isUppercase }))
            XCTAssertTrue(made.contains(where: { $0.isNumber }))
            XCTAssertTrue(made.contains(where: { !$0.isLetter && !$0.isNumber }))
        }
    }

    func testAGeneratedPasswordLeavesOutWhatWasNotAsked() {
        let recipe = Vault.Recipe(length: 16, digits: false, symbols: false, plain: true)
        for _ in 0..<50 {
            let made = Vault.generate(recipe)
            XCTAssertEqual(made.count, 16)
            XCTAssertTrue(made.allSatisfy { $0.isLetter })
            XCTAssertFalse(made.contains(where: { "l1IO0".contains($0) }), "no look-alikes: \(made)")
        }
    }

    func testTwoGeneratedPasswordsDiffer() {
        XCTAssertNotEqual(Vault.generate(Vault.Recipe()), Vault.generate(Vault.Recipe()))
    }

    func testTooShortARecipeStillHoldsOneOfEachKind() {
        let made = Vault.generate(Vault.Recipe(length: 2, digits: true, symbols: true, plain: true))
        XCTAssertEqual(made.count, 4)
    }

    // MARK: - how good one is

    func testTheOnesEverybodyTriesAreWeakWhateverTheyLookLike() {
        XCTAssertEqual(Vault.strength(of: "Password").grade, .weak)
        XCTAssertEqual(Vault.strength(of: "P@ssw0rd").grade, .weak)
        XCTAssertEqual(Vault.strength(of: "123456789").grade, .weak)
        XCTAssertEqual(Vault.strength(of: "").grade, .weak)
    }

    func testShortOrOneKindIsWeak() {
        XCTAssertEqual(Vault.strength(of: "abcdefg").grade, .weak, "seven letters")
        XCTAssertEqual(Vault.strength(of: "abcdefgh").grade, .weak, "eight lowercase: under 40 bits")
    }

    func testLongAndMixedIsStrong() {
        let graded = Vault.strength(of: "vK7#qm2Rb!xT9w&Lp4Zs")
        XCTAssertEqual(graded.grade, .strong)
        XCTAssertGreaterThan(graded.bits, 100)
        XCTAssertEqual(Vault.strength(of: "abcdefghij12").grade, .fair, "twelve of letters and digits: about 62 bits")
        XCTAssertEqual(Vault.strength(of: Vault.generate(Vault.Recipe())).grade, .strong)
    }

    // MARK: - the checkup

    private func kept(_ host: String, _ user: String = "me", clear: Bool = false) -> Kept {
        Kept(host: host, user: user, clear: clear)
    }

    func testTheCheckupFlagsWeakReusedAndClearOnceEach() {
        let shared = "vK7#qm2Rb!xT9w&Lp4Zs"
        let items: [(kept: Kept, password: String)] = [
            (kept("example.com"), shared),
            (kept("example.org"), shared),
            (kept("router.local", "admin", clear: true), "admin"),
            (kept("fine.example"), "Qx9!mN4#pL2@vB7&kS1z"),
        ]
        let checkup = Vault.audit(items)
        XCTAssertEqual(checkup.checked, 4)
        XCTAssertEqual(checkup.weak, 1)
        XCTAssertEqual(checkup.reused, 2)
        XCTAssertEqual(checkup.clear, 1)
        XCTAssertEqual(checkup.flags.map(\.kept.host), ["example.com", "example.org", "router.local"], "the worst first, the fine one not listed")
        let router = checkup.flags.first { $0.kept.host == "router.local" }
        XCTAssertEqual(router?.weak, true)
        XCTAssertEqual(router?.clear, true)
        XCTAssertEqual(router?.sharedWith, 0)
        XCTAssertEqual(checkup.flags.first?.sharedWith, 1)
    }

    func testTheCheckupHasNothingToSayAboutGoodPasswords() {
        let checkup = Vault.audit([(kept: kept("a.example"), password: "Qx9!mN4#pL2@vB7&kS1z"),
                                   (kept: kept("b.example"), password: "Zr3$wT8*hF6^nK2!dM5q")])
        XCTAssertTrue(checkup.flags.isEmpty)
        XCTAssertEqual(checkup.checked, 2)
    }

    func testTheCheckupOfNothingIsEmpty() {
        let checkup = Vault.audit([])
        XCTAssertTrue(checkup.flags.isEmpty)
        XCTAssertEqual(checkup.checked, 0)
    }
}
