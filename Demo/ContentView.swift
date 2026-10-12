import OutcomeTelemetry
import OutcomeTelemetryUI
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: DemoModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Network-fault scenarios lead with the device pipeline,
                    // which is what they exercise; the default leads with the report.
                    if model.scenario == .standard {
                        fleetSection
                        Divider()
                        deviceSection
                    } else {
                        deviceSection
                        Divider()
                        fleetSection
                    }
                }
                .padding()
            }
            .navigationTitle("Outcome Telemetry")
        }
    }

    private var fleetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture an expense · fleet").font(.headline)
            Text(model.fleetSummary).font(.caption).foregroundStyle(.secondary)
            if let report = model.report {
                OutcomeDashboard(report: report, featureName: "AI auto-category")
            } else {
                ProgressView()
            }
            Button("Re-run fleet with a new seed") { Task { await model.rerunFleet() } }
                .buttonStyle(.bordered)
                .disabled(model.busy)
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This device's pipeline").font(.headline)
            Text("Scenario: \(model.scenario.rawValue)").font(.caption).foregroundStyle(.secondary)
            Picker("Network", selection: Binding(
                get: { model.network },
                set: { mode in Task { await model.setNetwork(mode) } }
            )) {
                Text("Healthy").tag(InMemoryCollector.Mode.healthy)
                Text("Offline").tag(InMemoryCollector.Mode.offline)
                Text("Lost acks").tag(InMemoryCollector.Mode.lostAcks)
                Text("Rejecting").tag(InMemoryCollector.Mode.rejecting)
            }
            .pickerStyle(.segmented)
            HStack {
                Button("Run 10 tasks") { Task { await model.runTasks(10) } }
                Button("Seal") { Task { await model.seal() } }
                Button("Flush") { Task { await model.flushOnce() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.deviceBusy)
            if let health = model.health {
                PipelineHealthView(health: health, serverDuplicates: model.serverDuplicates)
            }
        }
    }
}
