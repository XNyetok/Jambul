import Foundation
import Testing
@testable import Jambul

/// The reports below follow the shapes each tool writes, with made-up numbers.
struct UsageParsingTests {
    @Test func readsClaudesWindowsFromTheStatusLine() throws {
        let input = Data("""
            {"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1800000000},\
            "seven_day":{"used_percentage":63.5,"resets_at":"2027-01-15T09:00:00Z"}}}
            """.utf8)
        let windows = try #require(UsageParsing.claudeWindows(fromStatusLine: input))
        #expect(windows.map(\.id) == ["five_hour", "seven_day"])
        #expect(windows.map(\.label) == ["5h", "7d"])
        #expect(windows[0].used == 0.42)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(windows[1].used == 0.635)
        #expect(windows[1].resetsAt == (try Date("2027-01-15T09:00:00Z", strategy: .iso8601)))
    }

    @Test func aStatusLineWithoutLimitsHasNoWindows() {
        // API accounts, and a session before its first reply.
        #expect(UsageParsing.claudeWindows(fromStatusLine: Data(#"{"model":{"display_name":"Opus"}}"#.utf8)) == nil)
        #expect(UsageParsing.claudeWindows(fromStatusLine: Data(#"{"rate_limits":{}}"#.utf8)) == nil)
        #expect(UsageParsing.claudeWindows(fromStatusLine: Data("not json".utf8)) == nil)
    }

    @Test func aMissingWindowLeavesTheOther() throws {
        let input = Data(#"{"rate_limits":{"seven_day":{"used_percentage":12}}}"#.utf8)
        let windows = try #require(UsageParsing.claudeWindows(fromStatusLine: input))
        #expect(windows.map(\.id) == ["seven_day"])
        #expect(windows[0].resetsAt == nil)
    }

    @Test func percentagesStayBetweenNothingAndAll() throws {
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":130},"seven_day":{"used_percentage":-5}}}"#.utf8)
        let windows = try #require(UsageParsing.claudeWindows(fromStatusLine: input))
        #expect(windows.map(\.used) == [1, 0])
    }

    @Test func aBooleanIsNotAPercentage() {
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":true}}}"#.utf8)
        #expect(UsageParsing.claudeWindows(fromStatusLine: input) == nil)
    }

    @Test func readsEveryAntigravityBucket() throws {
        let report = Data("""
            {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[
              {"name":"Gemini Models","buckets":[
                {"id":"gemini-weekly","window":"weekly","remaining_fraction":0.9,"reset_time":"2030-01-08T00:00:00Z"},
                {"id":"gemini-5h","window":"5h","remaining_fraction":1,"reset_time":"2030-01-01T05:00:00Z"}]},
              {"name":"Claude and GPT models","buckets":[
                {"id":"3p-weekly","window":"weekly","remaining_fraction":0.25,"reset_time":"2030-01-15T00:00:00Z"}]}]}}}
            """.utf8)
        let windows = try #require(UsageParsing.antigravityWindows(fromReport: report))
        #expect(windows.map(\.id) == ["gemini-weekly", "gemini-5h", "3p-weekly"])
        #expect(windows.map(\.label) == ["wk", "5h", "wk"])
        #expect(abs(windows[0].used - 0.1) < 1e-9)
        #expect(windows[1].used == 0)
        #expect(windows[2].used == 0.75)
        #expect(windows[2].resetsAt == (try Date("2030-01-15T00:00:00Z", strategy: .iso8601)))
    }

    @Test func aFailedAntigravityReportHasNoWindows() {
        let failed = Data(#"{"status":"ERROR","command":{"name":"usage","data":{"groups":[]}}}"#.utf8)
        #expect(UsageParsing.antigravityWindows(fromReport: failed) == nil)
        #expect(UsageParsing.antigravityWindows(fromReport: Data("{}".utf8)) == nil)
    }

    @Test func readsTheLastLimitsInACodexLog() throws {
        let log = """
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,\
            "window_minutes":300,"resets_at":1800000000},"secondary":null}}}
            {"type":"response_item","payload":{"type":"message"}}
            {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37.5,\
            "window_minutes":300,"resets_at":1800003600},"secondary":{"used_percent":80,"window_minutes":10080,\
            "resets_at":1800500000}}}}
            {"type":"response_item","payload":{"type":"message"}}
            """
        let windows = try #require(UsageParsing.codexWindows(fromSessionLog: log))
        #expect(windows.map(\.id) == ["primary", "secondary"])
        #expect(windows.map(\.label) == ["5h", "wk"])
        #expect(windows.map(\.used) == [0.375, 0.8])
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_800_003_600))
    }

    @Test func otherLimitsInACodexLogDontCount() throws {
        let log = """
            {"payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":20,"window_minutes":300}}}}
            {"payload":{"rate_limits":{"limit_id":"premium","primary":{"used_percent":90,"window_minutes":300}}}}
            """
        let windows = try #require(UsageParsing.codexWindows(fromSessionLog: log))
        #expect(windows.map(\.used) == [0.2])
    }

    @Test func aCodexLogWithoutLimitsHasNoWindows() {
        #expect(UsageParsing.codexWindows(fromSessionLog: #"{"type":"response_item"}"#) == nil)
        // The end of a log can start halfway through a line.
        #expect(UsageParsing.codexWindows(fromSessionLog: #"5,"rate_limits":{"primary":{"used_percent":1}}}}"#) == nil)
    }

    @Test(arguments: [(300, "5h"), (10_080, "wk"), (43_200, "30d"), (1_440, "1d"), (90, "90m")])
    func namesAWindowByItsLength(minutes: Int, label: String) {
        #expect(UsageParsing.label(forMinutes: minutes) == label)
    }

    @Test func aWindowIsEmptyOnceItResets() {
        let resetsAt = Date(timeIntervalSince1970: 1_000)
        let window = UsageWindow(id: "five_hour", label: "5h", used: 0.9, resetsAt: resetsAt)
        #expect(window.used(at: resetsAt.addingTimeInterval(-1)) == 0.9)
        #expect(window.used(at: resetsAt) == 0)
        #expect(UsageWindow(id: "x", label: "", used: 0.5, resetsAt: nil).used(at: .distantFuture) == 0.5)
    }

    @Test func theFullestWindowCounts() {
        let now = Date(timeIntervalSince1970: 1_000)
        let reading = UsageReading(provider: .claude, windows: [
            UsageWindow(id: "five_hour", label: "5h", used: 0.99, resetsAt: now.addingTimeInterval(-1)),
            UsageWindow(id: "seven_day", label: "7d", used: 0.6, resetsAt: now.addingTimeInterval(3_600)),
        ], measuredAt: now)
        // The five-hour window has started over, so the weekly one is fuller now.
        #expect(reading.fullest(at: now)?.id == "seven_day")
    }
}
