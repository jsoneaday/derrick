import Testing
@testable import ui

@MainActor
@Suite struct CoalescedMainActorWorkTests {
    @Test func overlappingSchedulesCollapseToOneFollowUp() async {
        let work = CoalescedMainActorWork()
        let gate = WorkGate()
        var runs = 0

        work.schedule {
            runs += 1
            if runs == 1 {
                await gate.wait()
            }
        }
        while !gate.started {
            await Task.yield()
        }
        work.schedule {}
        work.schedule {}
        gate.open()

        while runs < 2 {
            await Task.yield()
        }
        #expect(runs == 2)
    }
}

@MainActor
private final class WorkGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false

    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.started = true
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}
