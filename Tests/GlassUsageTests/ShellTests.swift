import Foundation
import Testing
@testable import GlassUsage

/// `Shell.run` drives the provider CLIs; a run that never returns stops every refresh until relaunch.
@Suite struct ShellTests {
    @Test func collectsBothStreamsAndTheExitStatus() async throws {
        let output = try await Shell.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
    }

    @Test func returnsWhenAHelperTheCommandStartedKeepsThePipesOpen() async throws {
        let start = Date.now
        let output = try await Shell.run("/bin/sh", ["-c", "sleep 30 & echo done"], timeout: 10)
        #expect(output.stdout == "done\n")
        #expect(Date.now.timeIntervalSince(start) < 5)
    }

    @Test func killsACommandThatIgnoresTermination() async throws {
        let start = Date.now
        let output = try await Shell.run("/bin/sh", ["-c", "trap '' TERM; while :; do sleep 0.1; done"], timeout: 1)
        #expect(output.status != 0)
        #expect(Date.now.timeIntervalSince(start) < 8)
    }
}
