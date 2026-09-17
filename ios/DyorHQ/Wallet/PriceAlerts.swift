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

/// Local, on-device storage for price alerts. Kept out of the backend for now (server push would need APNs); the
/// in-app watcher fires a local notification when one triggers.
enum PriceAlertStore {
    private static let key = "priceAlerts.v1"

    static func all() -> [PriceAlert] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([PriceAlert].self, from: data)) ?? []
    }

    /// Mirrors the list to the backend (installed by the app environment).
    nonisolated(unsafe) static var onChange: (([PriceAlert]) -> Void)?

    static func save(_ alerts: [PriceAlert]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(alerts), forKey: key)
        onChange?(alerts)
    }

    static func add(_ alert: PriceAlert) { var a = all(); a.append(alert); save(a) }
    static func remove(_ id: UUID) { save(all().filter { $0.id != id }) }
}

/// Polls prices for the alerted tokens and fires a local notification when one crosses its target, then removes it.
/// Runs while the app is alive (foreground or a background refresh); durable push would need a server + APNs.
@MainActor
final class AlertWatcher {
    private var task: Task<Void, Never>?

    func start(env: AppEnvironment, settings: AppSettings) {
        guard task == nil else { return }
        task = Task { [weak env, weak settings] in
            while !Task.isCancelled {
                if let env, let settings { await Self.check(env: env, settings: settings) }
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    private static func check(env: AppEnvironment, settings: AppSettings) async {
        guard settings.notificationsEnabled, settings.notifyPriceAlerts else { return }
        let alerts = PriceAlertStore.all()
        guard !alerts.isEmpty else { return }
        let tokens = alerts.map { Token(address: $0.token, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) }
        guard let prices = try? await env.prices.prices(for: tokens) else { return }
        var remaining = alerts
        for alert in alerts {
            guard let price = prices[alert.token]?.usd else { continue }
            let crossed = alert.above ? price >= alert.target : price <= alert.target
            if crossed {
                Notifications.priceAlert(symbol: alert.symbol, above: alert.above, target: alert.target, price: price)
                remaining.removeAll { $0.id == alert.id }
            }
        }
        if remaining.count != alerts.count { PriceAlertStore.save(remaining) }
    }
}

/// Lists the user's price alerts and lets them add or delete one.
struct PriceAlertsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(AppSettings.self) private var settings
    @State private var alerts = PriceAlertStore.all()
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
                    Text("No price alerts yet. Add one to get notified when a token hits your target.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    ForEach(alerts) { alert in
                        HStack(spacing: 12) {
                            TokenLogo(symbol: alert.symbol, url: nil, size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(alert.symbol).font(.subheadline.weight(.semibold))
                                Text("\(alert.above ? "Above" : "Below") \(NumberStyle.number(alert.target)) USD").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: alert.above ? "arrow.up.right" : "arrow.down.right")
                                .foregroundStyle(alert.above ? Color.positive : Color.negative)
                        }
                    }
                    .onDelete { indexSet in
                        for i in indexSet { PriceAlertStore.remove(alerts[i].id) }
                        alerts = PriceAlertStore.all()
                    }
                }
            } header: {
                HStack {
                    Text("Your Alerts")
                    Spacer()
                    Button { Haptics.tap(); showCreate = true } label: { Label("Add", systemImage: "plus") }.textCase(nil)
                }
            }
        }
        .navigationTitle("Price Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreate) { CreateAlertView { alerts = PriceAlertStore.all() } }
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
    private var target: Double? { Double(targetText) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Token") {
                    Picker("Token", selection: Binding(get: { token.address }, set: { addr in if let t = universe.first(where: { $0.address == addr }) { token = t } })) {
                        ForEach(universe) { Text($0.symbol).tag($0.address) }
                    }
                    if let currentPrice {
                        LabeledContent("Current price", value: NumberStyle.number(currentPrice) + " USD")
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
                        TextField("0.00", text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit().frame(maxWidth: 120)
                        Text("USD").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("You'll get a notification the next time \(token.symbol) \(above ? "rises above" : "falls below") this price.")
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
        PriceAlertStore.add(PriceAlert(token: token.address, symbol: token.symbol, decimals: token.decimals, target: t, above: above))
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
