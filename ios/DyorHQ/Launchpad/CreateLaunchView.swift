import BigInt
import DyorKit
import PhotosUI
import SwiftUI

/// Launch a coin: pick its image, name and ticker, describe it, choose the pairing asset and economics, optionally
/// buy first. A live "Your coin" card mirrors the discovery grid as you fill it in — the Ponsfamily create flow in
/// DyorHQ's system.
struct CreateLaunchView: View {
    let protocolInfo: ProtocolInfo?
    let onLaunched: () -> Void
    @Environment(AppEnvironment.self) private var env
    @Environment(Session.self) private var session
    @Environment(Router.self) private var router
    @Environment(SocialSession.self) private var social
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = ""
    @State private var description = ""
    @State private var logo = ""
    @State private var website = ""
    @State private var twitter = ""
    @State private var telegram = ""
    @State private var pair: Address = .zero
    @State private var venue: GraduationVenue = .uniswapV4
    @State private var creatorTaxBps = 0
    @State private var holderFeeSharing = true
    @State private var initialBuyText = ""
    @State private var showAdvanced = false
    @State private var showConfirm = false
    @State private var photoItem: PhotosPickerItem?
    @State private var uploadingImage = false
    @State private var imageError: String?

    private var symbolValid: Bool { symbol.count >= 2 && symbol.count <= 10 && symbol.allSatisfy { $0.isLetter || $0.isNumber } }
    /// Why this name or ticker can't be launched (`SymbolSafety.createRefusal`): one that reads as a token DyorHQ lists or a
    /// widely traded one, a ticker that doesn't show as itself, a name with hidden characters or longer than 32. Said under
    /// its field, and Review stays off, so a coin made here never carries a warning.
    private var refusal: SymbolSafety.CreateRefusal? {
        SymbolSafety.createRefusal(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, maxName: SymbolSafety.maxLaunchNameLength)
    }
    private var valid: Bool { name.trimmingCharacters(in: .whitespaces).count >= 2 && symbolValid && refusal == nil }
    /// Why the factory would refuse this launch (v2's unsealed or unexpected modules, template 0 switched off, or a
    /// whitelist this wallet isn't on): Review stays off, so nothing, not even a developer buy's approval, is signed.
    /// The launch plan checks again from a fresh read.
    private var blocker: String? {
        guard let protocolInfo else { return tr("The launchpad's terms couldn't be read. Close this screen and try again.") }
        return protocolInfo.launchBlocker?.message
    }
    private var pairInfo: PairInfo? { protocolInfo?.pairs.first { $0.pair.address == pair }?.pair }
    private var initialBuy: BigUInt { Amount.parse(initialBuyText, decimals: pairInfo?.decimals ?? 18) ?? 0 }
    /// aBIL (and any `pairMondayOnly` pair) can only graduate on Monday Trade; the factory reverts `PairRequiresMonday`
    /// if a v4 venue is submitted for one. The picker is then forced to Monday and disabled.
    private var pairMondayOnly: Bool { protocolInfo?.pairs.first { $0.pair.address == pair }?.mondayOnly ?? false }
    /// The venue actually submitted: forced to Monday for Monday-only pairs regardless of the picker's state.
    private var effectiveVenue: GraduationVenue { pairMondayOnly ? .monday : venue }

    var body: some View {
        NavigationStack {
            Form {
                if let blocker {
                    Section {
                        Label(blocker, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(Color.attention)
                    }
                }
                imageSection
                previewSection

                Section("Coin") {
                    TextField("Name", text: $name)
                        .onChange(of: name) { _, v in if v.count > SymbolSafety.maxLaunchNameLength { name = String(v.prefix(SymbolSafety.maxLaunchNameLength)) } }
                    if let refusal, !refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    // Letters of any script and digits: accented Latin, Chinese, Japanese and Korean pass; the guard says
                    // what doesn't show as itself.
                    TextField("Ticker", text: $symbol)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: symbol) { _, v in symbol = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }
                    if let refusal, refusal.isAboutSymbol { InlineError(message: refusal.message) }
                    TextField("Description", text: $description, axis: .vertical).lineLimit(2...5)
                }
                Section("Links") {
                    TextField("Website", text: $website).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("X profile", text: $twitter).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("Telegram", text: $telegram).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Picker("Paired with", selection: $pair) {
                        ForEach(protocolInfo?.pairs.filter(\.approved) ?? [], id: \.pair.address) { Text($0.pair.symbol).tag($0.pair.address) }
                    }
                    Picker("Graduates on", selection: $venue) {
                        Text(GraduationVenue.uniswapV4.title).tag(GraduationVenue.uniswapV4)
                        Text(GraduationVenue.monday.title).tag(GraduationVenue.monday)
                    }
                    .disabled(pairMondayOnly)
                    .onChange(of: pair) { _, _ in if pairMondayOnly { venue = .monday } }
                } header: {
                    Text("Pairing")
                } footer: {
                    if let info = protocolInfo, let pi = pairInfo {
                        VStack(alignment: .leading, spacing: 4) {
                            if pairMondayOnly {
                                Paragraph("Graduates to a locked \(effectiveVenue.title) pool once the curve raises \(NumberStyle.units(pairGraduation, decimals: pi.decimals, compact: true)) \(pi.symbol). A \(pi.symbol) coin graduates on Monday Trade; if it stays stuck for a day, anyone can move it to a locked Uniswap v4 pool. Launch fee \(NumberStyle.units(info.launchFee, decimals: 18)) MON.")
                            } else {
                                Paragraph("Graduates to a locked \(effectiveVenue.title) pool once the curve raises \(NumberStyle.units(pairGraduation, decimals: pi.decimals, compact: true)) \(pi.symbol). Launch fee \(NumberStyle.units(info.launchFee, decimals: 18)) MON.")
                            }
                            LearnMoreLink(.launchACoin)
                        }
                    }
                }
                Section {
                    AmountField(title: "0" as String, text: $initialBuyText, token: pairInfo.map { Token(address: $0.address, symbol: $0.symbol, name: $0.symbol, decimals: $0.decimals) })
                } header: {
                    Text("Developer Buy (Optional)")
                } footer: {
                    Paragraph("Buy your own coin in the same transaction — snipe-tax exempt.")
                }
                advancedSection
            }
            .navigationTitle(tr("Launch a Coin"))
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Review") { Haptics.tap(); showConfirm = true }.fontWeight(.semibold).disabled(!valid || blocker != nil) }
            }
            .sheet(isPresented: $showConfirm) {
                if let address = session.address, let info = protocolInfo {
                    // Use the async plan: it reads the launch fee and the on-chain economics hash the factory
                    // requires (`expectedEconomics`). The sync overload leaves that hash zero → LaunchEconomicsMismatch.
                    // Both are bound to what this screen showed: the fee, and the terms hash read with the terms.
                    ConfirmationSheet(
                        title: "Launch \(symbol)", confirmTitle: "Launch \(symbol)",
                        build: {
                            guard let shown = info.pairs.first(where: { $0.pair.address == pair })?.economicsHash else { throw LaunchpadError.termsChanged }
                            return try await env.launchpad.launchPlan(input, from: address, expectedLaunchFee: info.launchFee, expectedEconomics: shown)
                        },
                        onDone: { dismiss(); onLaunched() },
                        onCompleted: { hash in
                            Activity.record(ActivityRecord(kind: .launch, title: tr("Launched $\(symbol)"), subtitle: name.isEmpty ? symbol : name, hash: hash), owner: session.address)
                            // The new coin's picture and DyorHQ label, without waiting for the next 5-minute read.
                            Task { [coins = env.dyorCoins] in await coins.refresh() }
                            // Launched here, so chosen here: its coin is never shown as Unverified, on Home either (whose
                            // discovery would otherwise store it as merely found in the wallet's history). The coin is the
                            // one the live factory's event names for this wallet, never one a caller supplied.
                            let owner = session.address
                            let launchpad = env.launchpad
                            let multicall = env.multicall
                            let launched = input
                            Task { @MainActor in
                                guard let owner, let result = (try? await launchpad.launchResult(transaction: hash)) ?? nil, result.deployer == owner else { return }
                                let read = (try? await ERC20.metadata(result.token, multicall: multicall)) ?? nil
                                let symbol = read?.symbol ?? launched.symbol
                                KnownTokenStore.add(Token(address: result.token, symbol: symbol, name: read?.name ?? (launched.name.isEmpty ? symbol : launched.name), decimals: 18, isLaunchpad: true), owner: owner)
                                KnownTokenStore.markChosen(result.token, owner: owner)
                            }
                        },
                        onView: { hash in
                            // Route to the coin's in-app page instead of the block explorer (the explorer link lives
                            // in Recent Activity). Resolve the new token from the launch tx, then open its page. The
                            // launch was already recorded when it settled (`onCompleted`).
                            Task {
                                let detail = (try? await env.launchpad.launchResult(transaction: hash)).flatMap { $0 }
                                if let result = detail, let launch = (try? await env.launchpad.launch(token: result.token)) ?? nil {
                                    router.openLaunch(launch.launch)
                                    dismiss()
                                } else {
                                    _ = await UIApplication.shared.open(Monad.explorerTransaction(hash))
                                }
                            }
                        },
                        intent: .alwaysAsks(.launch)
                    ) {
                        DetailRow("Coin", verbatim: "\(name) ($\(symbol))")
                        DetailRow("Paired with", pairInfo?.symbol ?? "MON")
                        DetailRow("Graduation", verbatim: pairInfo.map { "\(NumberStyle.units(pairGraduation, decimals: $0.decimals, compact: true)) \($0.symbol)" } ?? "—")
                        DetailRow("Graduation venue", effectiveVenue.title)
                        DetailRow("Creator tax", NumberStyle.basisPoints(creatorTaxBps))
                        DetailRow("Fee sharing", holderFeeSharing ? "On" : "Off")
                        DetailRow("Launch fee", verbatim: "\(NumberStyle.units(info.launchFee, decimals: 18)) MON")
                        // The parsed amount — what is signed — not the typed text.
                        if initialBuy > 0 { DetailRow("Developer buy", verbatim: "\(NumberStyle.units(initialBuy, decimals: pairInfo?.decimals ?? 18)) \(pairInfo?.symbol ?? "MON")") }
                    }
                }
            }
            .onChange(of: photoItem) { _, item in if let item { Task { await uploadImage(item) } } }
            .onAppear { if pair.isZero, let first = protocolInfo?.pairs.first(where: \.approved) { pair = first.pair.address } }
        }
    }

    private var imageSection: some View {
        Section {
            HStack(spacing: 16) {
                LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo, pointSize: 72)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label(logo.isEmpty ? "Choose Image" : "Change Image", systemImage: "photo")
                            .font(.subheadline.weight(.medium))
                    }
                    .disabled(uploadingImage)
                    if uploadingImage {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Uploading…").font(.caption).foregroundStyle(.secondary) }
                    } else if let imageError {
                        Paragraph(imageError).font(.caption).foregroundStyle(Color.attention)
                    } else {
                        Text("Square images look best.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder private var previewSection: some View {
        if valid {
            Section {
                LaunchPreviewCard(name: name, symbol: symbol, logo: logo, pairSymbol: pairInfo?.symbol ?? "MON")
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            } header: {
                Text("Your Coin")
            }
        }
    }

    private var advancedSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showAdvanced) {
                Stepper("Creator tax \(NumberStyle.basisPoints(creatorTaxBps))", value: $creatorTaxBps, in: 0...(protocolInfo?.maxCreatorTaxBps ?? 0), step: 25)
                Toggle("Share fees with holders", isOn: $holderFeeSharing).tint(.brand)
            } label: {
                Label("Advanced", systemImage: "slider.horizontal.3")
            }
        } footer: {
            Paragraph(feeFooter)
        }
    }

    /// Where the creator tax and the creator's share of trading fees come from on the chosen venue: the curve and a
    /// Uniswap v4 pool's hook both pay them (to holders instead with fee sharing); a Monday Trade pool has no hook, and its
    /// 1% fee is harvested to DyorHQ (MondayFeeVault).
    private var feeFooter: String {
        let recipients = tr("You receive it with your share of the trading fees; with fee sharing on, holders receive both instead.")
        return effectiveVenue == .monday
            ? tr("Creator tax is charged on curve trades only. \(recipients) After graduation the Monday Trade pool's 1% fee goes to DyorHQ: there is no creator tax or fee share in the pool.")
            : tr("Creator tax is charged on curve trades and, after graduation, on Uniswap v4 pool swaps. \(recipients)")
    }

    private var pairGraduation: BigUInt {
        protocolInfo?.pairs.first { $0.pair.address == pair }?.graduationThreshold ?? 0
    }

    private func uploadImage(_ item: PhotosPickerItem) async {
        uploadingImage = true; imageError = nil
        defer { uploadingImage = false; photoItem = nil }
        do {
            // Uploading needs a DyorHQ Social session (same wallet); connect on demand.
            if !social.isSignedIn { await social.signIn(session: session) }
            guard social.isSignedIn else { imageError = tr("Connect DyorHQ Social to upload an image."); return }
            // The middle square, 512 pixels a side (`LaunchImage`): what the preview shows is what every screen shows.
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data),
                  let jpeg = image.launchJPEG() else {
                imageError = tr("That image could not be read.")
                return
            }
            logo = try await social.uploadLaunchImage(jpeg: jpeg).absoluteString
            Haptics.success()
        } catch {
            imageError = describe(error)
        }
    }

    private var input: LaunchInput {
        LaunchInput(name: name.trimmingCharacters(in: .whitespaces), symbol: symbol, description: description, logo: logo, socials: Socials(twitter: twitter, telegram: telegram, discord: "", website: website, farcaster: ""), creatorTaxBps: creatorTaxBps, holderFeeSharing: holderFeeSharing, graduationVenue: effectiveVenue, pairToken: pair, initialBuy: initialBuy)
    }
}

/// The live preview shown while creating a coin — the same shape as a discovery-grid card.
private struct LaunchPreviewCard: View {
    let name: String
    let symbol: String
    let logo: String
    let pairSymbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LaunchArtwork(symbol: symbol.isEmpty ? "?" : symbol, logo: logo)
                .aspectRatio(1, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .clipped()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    (name.isEmpty ? Text("Your coin") : Text(verbatim: name)).font(.subheadline.weight(.semibold)).lineLimit(1)
                    // not localized: a ticker stands in for the one still to be typed, as tickers are never translated.
                    Text(verbatim: "$\(symbol.isEmpty ? "TICKER" : symbol)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Spacer()
                }
                HStack {
                    Text("New", comment: "A badge on a new coin: just launched, or too new to have a 24h change [tight]").font(.caption2.weight(.semibold)).foregroundStyle(Color.brand)
                        .padding(.horizontal, 7).padding(.vertical, 2).background(Color.brand.opacity(0.14), in: Capsule())
                    Spacer()
                    Text("Pairs with \(pairSymbol)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
        }
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
