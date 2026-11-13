import Foundation
import Testing
@testable import Jambul

/// Stands in for agy and for the network: each run takes the next result, and the wait for the network is held until
/// the test lets it through. A run can be held too, like an agy that hangs.
@MainActor
private final class AgyStandIn {
    var results: [Result<Data, AntigravityUsageSource.RunFailure>]
    var holdsRuns = false
    private var held: CheckedContinuation<Void, Never>?
    private(set) var runs = 0
    private(set) var waiting: (@MainActor () -> Void)?
    private(set) var waits = 0
    private(set) var readings = 0
    private(set) var problems: [String] = []
    private(set) var source: AntigravityUsageSource!

    static let report = Data("""
        {"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models","buckets":[
        {"id":"gemini-5h","window":"5h","remaining_fraction":1,"reset_time":"2030-01-15T00:00:00Z"}]}]}}}
        """.utf8)

    init(_ results: [Result<Data, AntigravityUsageSource.RunFailure>]) {
        self.results = results
        source = AntigravityUsageSource(
            // No such folder, as on a Mac where agy hasn't run yet: nothing is watched.
            logFolder: URL(filePath: "/nonexistent/jambul-tests/agy-log"),
            findAgy: { URL(filePath: "/usr/bin/true") },
            report: { [weak self] _ in await self?.next() ?? .failure(.launch) },
            whenOnline: { [weak self] action in
                self?.waits += 1
                self?.waiting = action
                return { self?.waiting = nil }
            })
        source.onReading = { [weak self] _ in self?.readings += 1 }
        source.onProblem = { [weak self] in self?.problems.append($0) }
        source.start()
    }

    private func next() async -> Result<Data, AntigravityUsageSource.RunFailure> {
        runs += 1
        if holdsRuns { await withCheckedContinuation { held = $0 } }
        return results.isEmpty ? .failure(.timeout) : results.removeFirst()
    }

    var isRunning: Bool { held != nil }

    func letTheRunEnd() {
        held?.resume()
        held = nil
    }

    func comeOnline() {
        let action = waiting
        waiting = nil
        action?()
    }
}

@MainActor
struct AntigravityUsageSourceTests {
    @Test func aRunThatFailsIsTriedAgainOnceTheMacIsOnline() async throws {
        let agy = AgyStandIn([.failure(.timeout), .success(AgyStandIn.report)])
        agy.source.refresh()
        try await waitUntil { agy.waiting != nil }
        #expect(agy.problems == ["agy didn’t answer"])
        #expect(agy.runs == 1)

        agy.comeOnline()
        try await waitUntil { agy.readings == 1 }
        #expect(agy.runs == 2)
        #expect(agy.waits == 1)
    }

    @Test func anAgyThatStillDoesntAnswerIsLeftAlone() async throws {
        let agy = AgyStandIn([.failure(.timeout), .failure(.exit(1))])
        agy.source.refresh()
        try await waitUntil { agy.waiting != nil }
        agy.comeOnline()
        try await waitUntil { agy.problems.count == 2 }
        #expect(agy.runs == 2)
        #expect(agy.waits == 1)
        #expect(agy.waiting == nil)
    }

    @Test func aRunThatWorksWaitsForNothing() async throws {
        let agy = AgyStandIn([.success(AgyStandIn.report)])
        agy.source.refresh()
        try await waitUntil { agy.readings == 1 }
        #expect(agy.waits == 0)
        #expect(agy.problems.isEmpty)
    }

    @Test func turningAntigravityOffCallsTheRetryOff() async throws {
        let agy = AgyStandIn([.failure(.timeout), .success(AgyStandIn.report)])
        agy.source.refresh()
        try await waitUntil { agy.waiting != nil }
        agy.source.stop()
        #expect(agy.waiting == nil)
    }

    @Test func turnedOffWhileAgyRunsNothingWaitsForTheNetwork() async throws {
        let agy = AgyStandIn([.failure(.timeout)])
        agy.holdsRuns = true
        agy.source.refresh()
        try await waitUntil { agy.isRunning }
        agy.source.stop()
        agy.letTheRunEnd()
        try await waitUntil { agy.problems.count == 1 }
        #expect(agy.waits == 0)
    }

    @Test func aRunStartedMeanwhileTakesTheRetrysPlace() async throws {
        let agy = AgyStandIn([.failure(.timeout), .success(AgyStandIn.report)])
        agy.source.refresh()
        try await waitUntil { agy.waiting != nil }
        // The owner opens the Usage tab before the network is back, and the numbers count as old.
        agy.source.refresh(ifOlderThan: 0)
        #expect(agy.waiting == nil)
        try await waitUntil { agy.readings == 1 }
        #expect(agy.runs == 2)
    }
}
