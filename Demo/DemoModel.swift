import Foundation
import OutcomeTelemetry

/// Drives two things with the real library:
///
/// 1. **Fleet** — 240 simulated installs, randomised into AI-on and holdout,
///    each running real `OutcomeRecorder`s into one in-memory "server". The
///    report is built only from what that server received.
/// 2. **This device** — one recorder you can push around: run tasks, change
///    the network, seal, flush, and watch every task stay accounted for.
@MainActor
final class DemoModel: ObservableObject {
    @Published private(set) var report: OutcomeReport?
    @Published private(set) var fleetSummary = "Simulating 240 installs…"
    @Published private(set) var health: PipelineHealth?
    @Published private(set) var serverDuplicates: UInt64 = 0
    @Published private(set) var network: InMemoryCollector.Mode = .healthy
    /// True while the fleet simulation runs; the button is disabled and
    /// `rerunFleet` refuses to start a second run.
    @Published private(set) var busy = false
    /// True while a device action runs. Device actions are serialised: a tap
    /// during another action is ignored rather than interleaved across awaits.
    @Published private(set) var deviceBusy = false

    let scenario: Scenario
    private let clock = ManualClock(session: 1)
    private let deviceServer = InMemoryCollector()
    private let recorder: OutcomeRecorder
    private var rng = SplitMix64(seed: 99)
    private var fleetSeed = DemoPolicy.fleetSeed
    private var started = false

    init(scenario: Scenario) {
        self.scenario = scenario
        let cohorts = DemoPolicy.cohorts
        // Pick a device id that lands in the AI-on arm, so its AI events count.
        let deviceID = (0 ..< 1_000).lazy.map { "this-device-\($0)" }
            .first { cohorts.arm(forInstall: $0) == .treatment } ?? "this-device"
        let ids = SequentialIDs(prefix: "device")
        recorder = OutcomeRecorder(
            configuration: DemoPolicy.deviceConfiguration(),
            installID: deviceID,
            clock: clock,
            transport: deviceServer,
            makeBatchID: { ids.make() },
            jitter: { 1 }
        )
    }

    func start() async {
        guard !started else { return }
        started = true
        deviceBusy = true
        defer { deviceBusy = false }
        await runFleet()
        switch scenario {
        case .standard:
            await performTasks(24)
            await drain()
        case .offline:
            await setNetwork(.offline)
            for _ in 0 ..< 6 {
                await performTasks(10)
                await performFlush()
                clock.advance(seconds: 1)
            }
        case .lostAcks:
            await setNetwork(.lostAcks)
            await performTasks(12)
            await recorder.seal()
            for _ in 0 ..< 3 {
                await performFlush()
                clock.advance(seconds: 130)
            }
            await setNetwork(.healthy)
            await drain()
        }
        await refresh()
    }

    // MARK: Fleet

    func runFleet() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let seed = fleetSeed // captured before the await
        let server = InMemoryCollector()
        let result = await FleetSimulator.run(
            installs: DemoPolicy.fleetInstalls,
            tasksPerInstall: DemoPolicy.tasksPerInstall,
            seed: seed,
            cohorts: DemoPolicy.cohorts,
            gate: DemoPolicy.fleetGate,
            collector: server
        )
        let table = await server.table
        let outcomeOnly = await server.outcomeOnly
        // The design effect is estimated from per-install outcomes, as a
        // backend holding install-level aggregates would (see DesignEffect).
        report = OutcomeReport(kind: SampleSchema.captureExpense, table: table, outcomeOnly: outcomeOnly,
                               designEffect: result.designEffect)
        fleetSummary = "\(result.installs) installs (\(result.treatmentInstalls) AI on) · \(result.finishedTasks) tasks · \(result.conservedInstalls)/\(result.installs) pipelines conserved · seed \(seed)"
    }

    func rerunFleet() async {
        guard !busy else { return }
        fleetSeed = fleetSeed &+ 1
        await runFleet()
    }

    /// Runs one device action at a time; overlapping taps are dropped.
    private func exclusive(_ action: () async -> Void) async {
        guard !deviceBusy else { return }
        deviceBusy = true
        defer { deviceBusy = false }
        await action()
    }

    // MARK: This device

    func runTasks(_ count: Int) async {
        await exclusive { await performTasks(count) }
    }

    private func performTasks(_ count: Int) async {
        // A main-actor property cannot be passed `inout` across an await, so
        // the generator is copied out and written back.
        var generator = rng
        for _ in 0 ..< max(0, count) {
            await FleetSimulator.simulateTask(recorder: recorder, clock: clock, aiEnabled: recorder.aiEnabled, rng: &generator)
        }
        rng = generator
        await recorder.tick()
        await refresh()
    }

    func seal() async {
        await exclusive {
            await recorder.seal()
            await refresh()
        }
    }

    func flushOnce() async {
        await exclusive { await performFlush() }
    }

    private func performFlush() async {
        // A manual flush is a user action: skip any remaining backoff wait.
        await recorder.resetBackoff()
        _ = await recorder.flush()
        await refresh()
    }

    private func drain() async {
        await recorder.seal()
        await recorder.resetBackoff()
        for _ in 0 ..< 20 {
            let result = await recorder.flush()
            if case .sent = result { continue }
            break
        }
        await refresh()
    }

    func setNetwork(_ mode: InMemoryCollector.Mode) async {
        await deviceServer.setMode(mode)
        network = mode
    }

    func refresh() async {
        health = await recorder.health()
        serverDuplicates = await deviceServer.duplicateSends
    }
}
