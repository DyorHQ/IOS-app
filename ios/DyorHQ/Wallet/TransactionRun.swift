import DyorKit
import Foundation
import Observation
import SwiftUI

/// Drives one transaction plan from a confirmation sheet: runs the steps, records progress, surfaces errors.
@Observable
@MainActor
final class TransactionRun {
    enum Phase: Equatable { case idle, running, done(Data), failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var events: [TransactionEvent] = []

    var isRunning: Bool { phase == .running }
    var isDone: Bool { if case .done = phase { return true } else { return false } }

    func start(_ steps: [TransactionStep], session: Session, sender: TransactionSender) {
        guard !isRunning else { return }
        guard let wallet = session.wallet else {
            phase = .failed(SessionError.readOnly.localizedDescription)
            return
        }
        phase = .running
        events = []
        Task {
            do {
                let hash = try await sender.run(steps, from: wallet) { event in
                    Task { @MainActor in self.events.append(event) }
                }
                phase = .done(hash)
            } catch {
                phase = .failed(describe(error))
            }
        }
    }

    func reset() {
        phase = .idle
        events = []
    }
}

/// The standard confirm → progress → done sheet used by every write in the app. The step plan is built by an
/// async closure (some builders read the chain or an actor-isolated service), so the sheet shows a brief
/// "Preparing" state, then the confirm button, then live progress.
struct ConfirmationSheet<Details: View>: View {
    let title: String
    let confirmTitle: String
    var build: () async throws -> [TransactionStep]
    let onDone: () -> Void
    @ViewBuilder var details: Details

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var steps: [TransactionStep] = []
    @State private var buildError: String?
    @State private var preparing = true

    var body: some View {
        NavigationStack {
            List {
                Section { details }
                if preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                if let buildError {
                    Section { InlineError(message: buildError) }.listRowBackground(Color.clear)
                }
                if !run.events.isEmpty {
                    Section("Progress") { TransactionProgress(events: run.events) }
                }
                if case .failed(let message) = run.phase {
                    Section { InlineError(message: message) }.listRowBackground(Color.clear)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(run.isDone ? "Done" : "Cancel") {
                        dismiss()
                        if run.isDone { onDone() }
                    }
                    .disabled(run.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { dismiss(); onDone() }
                    } else if !session.canSign {
                        Text(SessionError.readOnly.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        PrimaryButton(title: confirmTitle, isBusy: run.isRunning, isDisabled: preparing || steps.isEmpty || buildError != nil) {
                            Task {
                                if settings.requireBiometrics, !(await BiometricGate.authenticate(reason: "Confirm \(confirmTitle)")) { return }
                                run.start(steps, session: session, sender: env.sender)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
            .interactiveDismissDisabled(run.isRunning)
        }
        .presentationDetents([.medium, .large])
        // Opaque on purpose: the list fades under the footer, and a translucent sheet would show the presenting
        // screen's dark primary button through that fade.
        .presentationBackground(Color(.systemGroupedBackground))
        .sensoryFeedback(.success, trigger: run.isDone)
        .task {
            do { steps = try await build() } catch { buildError = describe(error) }
            preparing = false
        }
    }
}
