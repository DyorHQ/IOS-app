import DyorKit
import Foundation
import Observation
import SwiftUI

/// The minimum supported build (security audit 2026-09-26, GP-2). A build that contains this check (the first after
/// build 13) and is below `app_config` 'ios'.min_build (supabase migration 28) shows `UpdateRequiredView` in place of the
/// app, where balances and key export stay reachable and nothing signs. Builds 13 and earlier never read it, so raising
/// min_build does nothing for them: the ones that hard-code retired contract stacks (12 and earlier) must still be
/// expired in App Store Connect and TestFlight. Read at launch and on every return to the foreground, at most once
/// every ten minutes. Fails open: a failed or unreadable check blocks nothing, and a block already seen this run stays
/// until a check says otherwise.
@Observable
@MainActor
final class UpdateGate {
    /// The row that retires this build, while it does.
    private(set) var required: MinimumBuild?
    @ObservationIgnored private var lastCheck: Date?
    @ObservationIgnored private var checking = false
    private static let interval: TimeInterval = 10 * 60
    private let bundleVersion = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    func check(client: SupabaseClient) async {
        guard !checking else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.interval { return }
        checking = true
        defer { checking = false }
        lastCheck = Date()
        // Fails open: an error or a missing or malformed row leaves things as they were.
        guard let minimum = try? await client.minimumBuild() else { return }
        required = minimum.requiresUpdate(bundleVersion: bundleVersion) ? minimum : nil
    }
}

/// "Update required" (GP-2): shown in place of the app while this build is below the minimum. It says what to do and
/// opens the update, shows the account's balances read-only, and keeps key export reachable — the funds never depend
/// on updating. Nothing on it signs, and nothing that signs is reachable from it.
struct UpdateRequiredView: View {
    let minimum: MinimumBuild
    @Environment(Session.self) private var session
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var assets = AssetsModel()

    private static let fallbackURL = URL(string: "https://testflight.apple.com")!

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(Color.brand)
                            .accessibilityHidden(true)
                        Text("Update required")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        Text(minimum.message.isEmpty ? "This version of DyorHQ is no longer supported. Update to trade, send and sign again. Your funds are safe in your wallet: you can still see your balances and export your wallet here." : minimum.message)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }

                Section {
                    PrimaryButton(title: "Update DyorHQ", systemImage: "arrow.down.circle") { openURL(minimum.url ?? Self.fallbackURL) }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if let address = session.address {
                    Section {
                        if assets.tokens.isEmpty {
                            Text(assets.loading || assets.loadedFor != address ? "Reading the wallet…" : "No tokens in this wallet.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(assets.tokens) { asset in
                            HStack {
                                Text(asset.token.symbol).fontWeight(.medium)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(NumberStyle.units(asset.balance, decimals: asset.token.decimals)).monospacedDigit()
                                    if let value = asset.value {
                                        Text(value, format: .currency(code: "USD").precision(.fractionLength(0...2)))
                                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Your balances")
                    } footer: {
                        Text("Held by \(address.short) on Monad. This version can't send, trade or sign anything.")
                    }

                    if session.canSign {
                        Section {
                            NavigationLink { WalletExportView() } label: { Label("Export Wallet", systemImage: "key.horizontal") }
                        } footer: {
                            Text("Your wallet's key or recovery phrase works in any other wallet app.")
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(SupportLinks.name)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: session.address) { await assets.load(env: env, address: session.address, force: false) }
        }
    }
}
