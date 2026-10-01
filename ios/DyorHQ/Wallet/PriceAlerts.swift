import DyorKit
import Foundation
import Observation
import SwiftUI

/// A price alert the user set: notify when `token` crosses `target` USD, from below (above == true) or above.
struct PriceAlert: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let token: Address
    let symbol: String
    let decimals: Int
    let target: Double
    let above: Bool
    var createdAt = Date()
}

/// On-device storage for price alerts, per wallet like the activity log and the notification center: each account
/// has its own alerts, and they are mirrored to that wallet's rows only (security audit 2026-09-26, RS-7). The in-app
/// watcher fires a local notification when one triggers.
enum PriceAlertStore {
    private static func key(_ owner: Address) -> String { "priceAlerts.v1.\(owner.hex)" }
    /// The device-wide list builds before per-wallet storage kept; it moves to the first wallet that reads its alerts.
    private static let legacyKey = "priceAlerts.v1"

    static func all(owner: Address?) -> [PriceAlert] {
        guard let owner else { return [] }
        adoptLegacy(owner: owner)
        guard let data = UserDefaults.standard.data(forKey: key(owner)) else { return [] }
        return (try? JSONDecoder().decode([PriceAlert].self, from: data)) ?? []
    }

    /// Mirrors a wallet's list to its backend rows (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([PriceAlert], Address) -> Void)?

    static func save(_ alerts: [PriceAlert], owner: Address?) {
        guard let owner else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(alerts), forKey: key(owner))
        onChange?(alerts, owner)
    }

    static func add(_ alert: PriceAlert, owner: Address?) { var a = all(owner: owner); a.append(alert); save(a, owner: owner) }
    static func remove(_ id: UUID, owner: Address?) { save(all(owner: owner).filter { $0.id != id }, owner: owner) }

    /// Drops the alerts that fired, re-reading the list first so one added or deleted meanwhile stays as it is.
    static func removeFired(_ ids: Set<UUID>, owner: Address) {
        guard !ids.isEmpty else { return }
        let current = all(owner: owner)
        let remaining = current.filter { !ids.contains($0.id) }
        if remaining.count != current.count { save(remaining, owner: owner) }
    }

    private static func adoptLegacy(owner: Address) {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.data(forKey: legacyKey) else { return }
        if defaults.data(forKey: key(owner)) == nil { defaults.set(legacy, forKey: key(owner)) }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// Polls prices for the alerted tokens and fires a local notification when one crosses its target, then removes it.
/// Runs only while the app runs: iOS suspends it soon after it leaves the foreground, and there is no background
/// refresh or push server (that would need a server-side watcher + APNs). So an alert fires at the first check that
/// finds its price crossed while the app is open, and a crossing that reverts while it is closed is never seen.
@MainActor
final class AlertWatcher {
    private var task: Task<Void, Never>?

    /// `owner` is the signed-in wallet, read on every check: only its alerts are watched.
    func start(env: AppEnvironment, settings: AppSettings, owner: @escaping @MainActor () -> Address?) {
        guard task == nil else { return }
        task = Task { [weak env, weak settings] in
            while !Task.isCancelled {
                if let env, let settings, let address = owner() { await Self.check(env: env, settings: settings, owner: address) }
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    private static func check(env: AppEnvironment, settings: AppSettings, owner: Address) async {
        guard settings.notificationsEnabled, settings.notifyPriceAlerts else { return }
        let alerts = PriceAlertStore.all(owner: owner)
        guard !alerts.isEmpty else { return }
        let tokens = alerts.map { Token(address: $0.token, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) }
        guard let prices = try? await env.prices.prices(for: tokens) else { return }
        // The account may have changed during the read: its alerts are not this one's to fire.
        guard NotificationHub.shared.owner == owner else { return }
        var fired: Set<UUID> = []
        for alert in alerts {
            guard let price = prices[alert.token]?.usd else { continue }
            let crossed = alert.above ? price >= alert.target : price <= alert.target
            if crossed {
                Notifications.priceAlert(symbol: alert.symbol, above: alert.above, target: alert.target, price: price)
                fired.insert(alert.id)
            }
        }
        PriceAlertStore.removeFired(fired, owner: owner)
    }
}

/// Lists the user's price alerts and lets them add or delete one.
struct PriceAlertsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var alerts: [PriceAlert] = []
    @State private var showCreate = false

    var body: some View {
        List {
            if !settings.notificationsEnabled || !settings.notifyPriceAlerts {
                Section {
                    Label("Turn on Notifications and Price Alerts above to receive these.", systemImage: "bell.slash")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Section {
                if alerts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No price alerts yet.").font(.subheadline.weight(.medium))
                        Button("Add an Alert", systemImage: "plus") { Haptics.tap(); showCreate = true }
                            .font(.subheadline).buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                } else {
                    ForEach(alerts) { alert in
                        HStack(spacing: 12) {
                            TokenLogo(symbol: alert.symbol, url: nil, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.symbol).font(.subheadline.weight(.semibold))
                                Text("\(alert.above ? "Above" : "Below") \(PriceFormat.usdPrice(alert.target))").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityLabel("\(alert.above ? "Above" : "Below") \(PriceFormat.spoken(alert.target))")
                            }
                            Spacer()
                            Image(systemName: alert.above ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(alert.above ? Color.positive : Color.negative)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { PriceAlertStore.remove(alerts[i].id, owner: session.address) }
                        alerts = PriceAlertStore.all(owner: session.address)
                    }
                }
            } header: {
                HStack {
                    Text("Your Alerts")
                    Spacer()
                    Button { Haptics.tap(); showCreate = true } label: { Label("Add", systemImage: "plus") }.textCase(nil)
                }
            } footer: {
                Text("DyorHQ checks alerts about once a minute, and only while it's open. iOS pauses the app in the background, so an alert can't reach your lock screen while DyorHQ is closed, and a price that crosses and comes back in the meantime isn't reported. To protect a perp position, set a stop-loss on it.")
            }
        }
        .navigationTitle("Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreate) { CreateAlertView { alerts = PriceAlertStore.all(owner: session.address) } }
        .task(id: session.address) { alerts = PriceAlertStore.all(owner: session.address) }
    }
}

/// Pick a token, see its live price, set a target above or below it.
private struct CreateAlertView: View {
    let onSaved: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var token: Token = .mon
    @State private var targetText = ""
    @State private var above = true
    @State private var currentPrice: Double?

    private var universe: [Token] { KnownTokenStore.universe(owner: session.address).filter { $0.symbol != "WMON" } }
    /// The typed target, read like an amount field (`PriceAlertTarget.parse`): "0,03" from a comma-decimal keypad is
    /// three cents, and a dust target keeps every digit.
    private var target: Double? { PriceAlertTarget.parse(targetText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Token") {
                    Picker("Token", selection: Binding(get: { token.address }, set: { addr in if let t = universe.first(where: { $0.address == addr }) { token = t } })) {
                        ForEach(universe) { Text($0.symbol).tag($0.address) }
                    }
                    if let currentPrice {
                        LabeledContent("Current price") { Text(PriceFormat.usdPrice(currentPrice)).accessibilityLabel(PriceFormat.spoken(currentPrice)) }
                    }
                }
                Section {
                    Picker("Notify when", selection: $above) {
                        Text("Rises above").tag(true)
                        Text("Falls below").tag(false)
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Text("Target")
                        Spacer()
                        // Takes the row's free width first (up to 220 pt), so a dust target such as 0.00000006 shows in full.
                        TextField("0.00", text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                            .frame(minWidth: 120, maxWidth: 220).layoutPriority(1)
                        Text("USD").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("DyorHQ notifies you when it finds \(token.symbol) \(above ? "above" : "below") this price. It checks about once a minute, only while the app is open.")
                }
            }
            .navigationTitle("New Alert")
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { save() }.fontWeight(.semibold).disabled((target ?? 0) <= 0) }
            }
            .task(id: token.address) { await loadPrice() }
        }
    }

    private func loadPrice() async {
        currentPrice = nil
        currentPrice = (try? await env.prices.prices(for: [token]))?[token.address]?.usd
        // Default the direction to whichever side the target would need to move from the current price.
        if let price = currentPrice, let t = target { above = t >= price }
    }

    private func save() {
        guard let t = target, t > 0 else { return }
        PriceAlertStore.add(PriceAlert(token: token.address, symbol: token.symbol, decimals: token.decimals, target: t, above: above), owner: session.address)
        // Setting an alert implies you want it to fire, so turn the alert delivery on and make sure the OS
        // permission is granted — otherwise the watcher stays silent behind an off-by-default toggle.
        if !settings.notifyPriceAlerts { settings.notifyPriceAlerts = true }
        if !settings.notificationsEnabled { settings.notificationsEnabled = true }
        Task { _ = await Notifications.requestAuthorization() }
        Haptics.success()
        onSaved()
        dismiss()
    }
}
