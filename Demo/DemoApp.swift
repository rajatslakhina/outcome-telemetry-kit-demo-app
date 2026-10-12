import OutcomeTelemetry
import OutcomeTelemetryUI
import SwiftUI

/// The app owns its telemetry policy: the experiment (salt and split), the
/// privacy threshold and the batching limits. The library only enforces it.
enum DemoPolicy {
    /// 50/50 split for the AI auto-category experiment. Changing the salt
    /// re-randomises every install, so it is versioned with the experiment.
    static let cohorts = CohortAssigner(treatmentPerMille: 500, salt: "ai-autocategory-2026q4")

    /// No uploaded detail row may describe fewer than 3 tasks. With
    /// `maxCarries: 0` a small row is reduced to its outcome counts at the
    /// seal that produced it (each simulated install seals at every trip to
    /// the background and once at the end), so the gate is exercised hard.
    static let fleetGate = PrivacyGate(k: 3, maxCarries: 0)

    /// The on-device pipeline shown in the second panel: small batches and a
    /// small queue so back-pressure and retries are visible within seconds.
    static func deviceConfiguration() -> OutcomeConfiguration {
        OutcomeConfiguration(
            definitions: SampleSchema.definitions,
            cohorts: cohorts,
            gate: PrivacyGate(k: 3, maxCarries: 2),
            minTasksPerBatch: 10,
            maxBatchAgeSeconds: 600,
            journalCapacity: 3,
            maxAttempts: 8,
            retry: RetryPolicy(baseSeconds: 2, capSeconds: 120)
        )
    }

    static let fleetInstalls = 240
    static let tasksPerInstall = 12
    static let fleetSeed: UInt64 = 2026
}

/// Launch scenarios used by the CI Simulator run (`-scenario <name>`).
enum Scenario: String {
    case standard
    case offline
    case lostAcks = "lost-acks"

    static var current: Scenario {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "-scenario"), args.indices.contains(flag + 1) else { return .standard }
        return Scenario(rawValue: args[flag + 1]) ?? .standard
    }
}

@main
struct DemoApp: App {
    @StateObject private var model = DemoModel(scenario: Scenario.current)

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .task { await model.start() }
        }
    }
}
