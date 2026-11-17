import XCTest
@testable import Search

final class AIActivityTests: XCTestCase {
    func testStatusDistinguishesProviderWaitFromToolWorkWithoutInventingProgress() {
        let start = Date(timeIntervalSince1970: 10_000)
        var activity = AIActivity()
        activity.receive(.preparing, at: start)
        activity.receive(.waiting, at: start.addingTimeInterval(1))
        XCTAssertEqual(activity.status(at: start.addingTimeInterval(7)), "Waiting for the provider · 6s")
        XCTAssertEqual(activity.status(at: start.addingTimeInterval(32)), "Still waiting for the provider · 31s")
        XCTAssertTrue(activity.steps.isEmpty, "A wait is not evidence that a tool has run")
        activity.receive(.toolStarted("browser_snapshot"), at: start.addingTimeInterval(33))
        XCTAssertEqual(activity.phase, .tool)
        XCTAssertEqual(activity.steps.last?.title, "Read the page")
        XCTAssertFalse(activity.steps.last!.returned)
        activity.receive(.toolReturned())
        XCTAssertTrue(activity.steps.last!.returned)
        activity.receive(.waiting, at: start.addingTimeInterval(38))
        XCTAssertEqual(activity.status(at: start.addingTimeInterval(39)), "Waiting for the provider · 1s")
    }

    func testActivityIsBoundedAndNeverEchoesUnknownToolNames() {
        var activity = AIActivity()
        for _ in 0..<200 {
            activity.receive(.toolStarted("unknown-secret-token-password"))
            activity.receive(.toolReturned())
        }
        XCTAssertEqual(activity.steps.count, 120)
        XCTAssertEqual(activity.totalSteps, 200)
        XCTAssertTrue(activity.steps.allSatisfy { $0.title == "Run an analysis tool" && $0.returned })
        activity.finish()
        let finished = activity
        activity.receive(.toolStarted("browser_click"))
        XCTAssertEqual(activity, finished, "Late events cannot resume a stopped answer")
    }

    func testRepeatedAnswerDeltasDoNotResetElapsedTimeOrRepublishProgress() {
        var activity = AIActivity()
        activity.receive(.answering)
        let original = activity
        activity.receive(.answering, at: Date().addingTimeInterval(50))
        XCTAssertEqual(activity, original)
    }

    func testStoppingDoesNotMarkAnUnfinishedToolAsReturned() {
        var activity = AIActivity()
        activity.receive(.toolStarted("replace_selected_text"))
        activity.finish()
        XCTAssertEqual(activity.phase, .finished)
        XCTAssertFalse(activity.steps.last!.returned)
    }

    func testJavaScriptCommandsStayDistinctAndResultsAreAttachedToTheirOwnStep() {
        var activity = AIActivity()
        for code in ["return document.querySelectorAll('a').length", "return localStorage.length"] {
            activity.receive(.toolStarted("browser_evaluate", input: .init(tool: "browser_evaluate", arguments: ["code": code])))
            activity.receive(.toolReturned(.init(raw: "{\"ok\":true,\"result\":3}")))
        }
        XCTAssertEqual(activity.steps[0].input.command.text, "return document.querySelectorAll('a').length")
        XCTAssertEqual(activity.steps[0].input.summary, "Script · page elements")
        XCTAssertEqual(activity.steps[1].input.summary, "Script · browser storage")
        XCTAssertTrue(activity.steps.allSatisfy { $0.output?.result.text.contains("\"result\" : 3") == true })
        XCTAssertFalse(activity.steps[0].issue)
    }

    func testFailedChecksAndConsoleExceptionsAreNotLabeledAsSuccess() {
        for raw in ["{\"error\":\"Synthetic failure\"}", "{\"passed\":false}", "{\"wasThrown\":true}", "{\"isError\":true}",
                    "{\"evidence_id\":\"test\",\"data\":\"{\\\"passed\\\":false}\",\"more\":false}"] {
            XCTAssertTrue(AIActivity.Output(raw: raw).issue, raw)
        }
        XCTAssertFalse(AIActivity.Output(raw: "{\"result\":{\"error\":\"An arbitrary page value\"}}").issue)
    }

    func testHistoryRetainsAllThirteenStepsFromTheReportedCase() {
        var activity = AIActivity()
        for index in 1...13 {
            activity.receive(.toolStarted("browser_evaluate", input: .init(tool: "browser_evaluate", arguments: ["code": "return \(index)"])))
            activity.receive(.toolReturned(.init(raw: "{\"result\":\(index)}")))
        }
        XCTAssertEqual(activity.steps.count, 13)
        XCTAssertEqual(activity.steps.first?.number, 1)
        XCTAssertEqual(activity.steps.first?.input.command.text, "return 1")
        XCTAssertEqual(activity.steps.last?.number, 13)
    }

    func testLargeCommandsAndResultsHaveBoundedUnicodeSafeExcerpts() {
        let value = String(repeating: "🔐", count: 100_000)
        let input = AIActivity.Input(tool: "run_console", arguments: ["expression": value])
        let output = AIActivity.Output(raw: value)
        XCTAssertLessThanOrEqual(input.command.text.utf8.count, 4096)
        XCTAssertLessThanOrEqual(output.result.text.utf8.count, 8192)
        XCTAssertTrue(input.command.truncated && output.result.truncated)
        XCTAssertFalse(input.command.text.contains("�") || output.result.text.contains("�"))
        let partial = AIActivity.Output(raw: "{\"evidence_id\":\"test\",\"more\":true,\"data\":\"partial data\"}")
        XCTAssertTrue(partial.result.truncated)
        XCTAssertEqual(partial.result.text, "partial data")
    }

    func testCollapsedSummariesNeverEchoScriptLiteralsOrArguments() {
        let secret = "synthetic-password-and-token"
        let input = AIActivity.Input(tool: "browser_evaluate", arguments: ["code": "localStorage.setItem('token','\(secret)')"])
        XCTAssertFalse(input.summary.contains(secret))
        XCTAssertTrue(input.command.text.contains(secret), "The explicitly expanded input stays an honest copy of the actual command")
    }
}
