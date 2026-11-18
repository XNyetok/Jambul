import Foundation
import Testing
@testable import Jambul

@MainActor
struct CodexUsageSourceTests {
    @Test func asksTheAccountAgainEvenWithoutAnySessionLogs() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = try makeCodex(in: folder)
        let source = CodexUsageSource(sessionsFolder: folder.appending(path: "sessions"), findCodex: { codex })
        var readings: [UsageReading] = []
        source.onReading = { readings.append($0) }
        source.start()
        defer { source.stop() }
        try await waitUntil { readings.count == 1 }
        let first = try #require(readings.first)
        #expect(first.windows.map(\.used) == [0.12, 0.45])
        #expect(first.windows.map(\.label) == ["5h", "wk"])

        source.refresh(ifOlderThan: .zero)
        try await waitUntil { readings.count == 2 }
        #expect(readings.last?.windows == first.windows)
    }

    @Test func fallsBackToAQuotaEventAndRetriesWhenTheMacIsOnline() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sessions = folder.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: false)
        let withLimits = sessions.appending(path: "with-limits.jsonl")
        try Data(#"{"timestamp":1000,"payload":{"rate_limits":{"primary":{"used_percent":29}}}}"#.utf8)
            .write(to: withLimits)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_100)],
                                              ofItemAtPath: withLimits.path)
        try Data(#"{"type":"session_meta"}"#.utf8).write(to: sessions.appending(path: "newer.jsonl"))
        var codex = URL(filePath: "/usr/bin/false")
        var retry: (@MainActor () -> Void)?
        let source = CodexUsageSource(sessionsFolder: sessions, findCodex: { codex }, whenOnline: { action in
            retry = action
            return { retry = nil }
        })
        var readings: [UsageReading] = []
        source.onReading = { readings.append($0) }
        source.start()
        defer { source.stop() }
        try await waitUntil { retry != nil }
        #expect(readings.first?.windows.first?.used == 0.29)
        #expect(readings.first?.measuredAt == Date(timeIntervalSince1970: 1_000))

        codex = try makeCodex(in: folder)
        retry?()
        try await waitUntil { readings.count == 2 }
        #expect(retry == nil)
        #expect(readings.last?.windows.first?.used == 0.12)
    }

    @Test func stopsWaitingForACliThatDoesNotAnswerInTime() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let codex = try makeCodex(in: folder, delay: "sleep 0.5")
        let windows = await CodexAccountUsage.read(codex, timeout: .milliseconds(50))
        #expect(windows == nil)
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    private func makeCodex(in folder: URL, delay: String = "") throws -> URL {
        let codex = folder.appending(path: "codex")
        let script = #"""
            #!/bin/sh
            test "$1" = app-server || exit 1
            IFS= read -r init || exit 2
            case "$init" in *'"method":"initialize"'*) ;; *) exit 3;; esac
            printf '%s\n' '{"id":1,"result":{}}'
            IFS= read -r ready && IFS= read -r request || exit 4
            test "$ready" = '{"method":"initialized"}' || exit 5
            test "$request" = '{"id":2,"method":"account/rateLimits/read"}' || exit 6
            \#(delay)
            printf '%s\n' '{"method":"account/rateLimits/updated","params":{}}'
            printf '%s' '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":90}},'
            printf '%s\n' '"rateLimitsByLimitId":{"codex":{"limitId":"codex","primary":{"usedPercent":12,"windowDurationMins":300},"secondary":{"usedPercent":45,"windowDurationMins":10080}}}}}'
            """#
        try Data(script.utf8).write(to: codex)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codex.path)
        return codex
    }
}
