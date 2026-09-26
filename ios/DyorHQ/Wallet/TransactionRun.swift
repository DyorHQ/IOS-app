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
    /// The settled transaction hash once the plan's final step confirms, for callers that record or route on it.
    var doneHash: Data? { if case .done(let hash) = phase { return hash } else { return nil } }

    /// `action`: the sheet's declared intent for a passkey (Mera) account, so its session's scope check sees the whole
    /// plan (`Session.wallet(for:)`); nil for every other account, which signs exactly as before.
    func start(_ steps: [TransactionStep], session: Session, sender: TransactionSender, action: MeraSession.Action? = nil) {
        guard !isRunning else { return }
        guard let wallet = session.wallet(for: action) else {
            phase = .failed(SessionError.readOnly.localizedDescription)
            return
        }
        let passkey = session.isPasskeyAccount
        phase = .running
        events = []
        Task {
            do {
                let hash = try await sender.run(steps, from: wallet) { event in
                    Task { @MainActor in self.events.append(event) }
                }
                phase = .done(hash)
            } catch where passkey && isUserCancellation(error) {
                // A passkey prompt the person dismissed: say plainly what did and didn't happen.
                let sent = events.contains { if case .sent = $0 { return true } else { return false } }
                phase = .failed(sent ? "Stopped at \(BiometricGate.promptName). Only the steps above were sent." : Self.notSent)
            } catch {
                phase = .failed(describe(error))
            }
        }
    }

    /// A step-up the person cancelled before anything was signed.
    static let notSent = "Not sent. Nothing left your account."

    /// Shows a failure that happened before the plan started (a cancelled step-up).
    func fail(_ message: String) {
        guard !isRunning else { return }
        phase = .failed(message)
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
    /// Fired with the settled transaction hash when the sheet finishes, for callers that log the action or record it.
    var onCompleted: ((Data) -> Void)? = nil
    /// When set, the confirmed step's "View" control calls this with the tx hash instead of opening the block
    /// explorer — the launch flow uses it to route to the in-app coin page.
    var onView: ((Data) -> Void)? = nil
    /// What the plan does, for a passkey account's session scope (MERA-PLAN §3). A sheet that declares nothing asks
    /// for Face ID every time; other accounts ignore it.
    var intent: Mera.Intent = .ask
    @ViewBuilder var details: Details

    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var run = TransactionRun()
    @State private var steps: [TransactionStep] = []
    @State private var buildError: String?
    @State private var preparing = true
    /// A passkey account's badge: prompt-free in the live session, or Face ID and why. Re-read when the session opens
    /// or ends, so expiry changes the badge and the button in place — no pop-up, and nothing typed is lost.
    @State private var assessment: MeraSession.Assessment?
    @State private var approving = false

    private var confirmLabel: String {
        session.isPasskeyAccount && assessment?.needsFaceID == true ? "Confirm with \(BiometricGate.promptName)" : confirmTitle
    }

    var body: some View {
        NavigationStack {
            List {
                Section { details }
                if session.isPasskeyAccount, !preparing, buildError == nil, !run.isRunning, !run.isDone, let assessment {
                    Section { SessionScopeBadge(assessment: assessment) }
                }
                if preparing {
                    Section {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Preparing transaction").foregroundStyle(.secondary) }
                    }
                }
                if let buildError {
                    Section { InlineError(message: buildError) }.listRowBackground(Color.clear)
                }
                if !run.events.isEmpty {
                    Section("Progress") { TransactionProgress(events: run.events, onView: onView) }
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
                    Button(run.isDone ? "Done" : "Cancel") { finish() }
                    .disabled(run.isRunning)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if run.isDone {
                        PrimaryButton(title: "Done", systemImage: "checkmark") { finish() }
                    } else if !session.canSign {
                        Text(SessionError.readOnly.localizedDescription)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    } else {
                        PrimaryButton(title: confirmLabel, isBusy: run.isRunning || approving, isDisabled: preparing || steps.isEmpty || buildError != nil || assessment?.isRefused == true) {
                            Task { await confirm() }
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
        .task(id: scopeKey) { await reassess() }
    }

    /// Changes whenever the badge could: the plan arrives, or the passkey session opens, ends or is replaced.
    private var scopeKey: String {
        "\(preparing)-\(session.mera.isUnlocked)-\(session.mera.expiresAt?.timeIntervalSince1970 ?? 0)"
    }

    private func reassess() async {
        guard session.isPasskeyAccount, !preparing, buildError == nil else { assessment = nil; return }
        assessment = await session.mera.assess(steps, intent: intent, chainId: env.sender.chainId)
    }

    /// App Lock (never for a passkey account), then — when the badge says Face ID — the passkey prompt straight from
    /// the tap, approving this plan; then the plan. A passkey account whose badge said "No Face ID needed" signs in its
    /// session, and the wallet still checks every transaction: one that fails asks for Face ID right there.
    private func confirm() async {
        if settings.appLockApplies(to: session.account), !(await BiometricGate.authenticate(reason: "Confirm \(confirmTitle)")) { return }
        guard session.isPasskeyAccount else {
            run.start(steps, session: session, sender: env.sender)
            return
        }
        let action = MeraSession.Action(intent)
        if assessment?.needsFaceID == true {
            approving = true
            defer { approving = false }
            do {
                try await session.mera.approve(action)
            } catch where isUserCancellation(error) {
                run.fail(TransactionRun.notSent)
                return
            } catch {
                run.fail(describe(error))
                return
            }
        }
        run.start(steps, session: session, sender: env.sender, action: action)
    }

    /// Dismiss and, when the plan settled, notify the caller. `onCompleted` runs BEFORE `onDone` on purpose:
    /// callers clear their input in `onDone`, and `onCompleted` reads that live input to record the action, so it
    /// must see the amount before it is cleared.
    private func finish() {
        let hash = run.doneHash
        dismiss()
        if run.isDone {
            if let hash { onCompleted?(hash) }
            onDone()
        }
    }
}
