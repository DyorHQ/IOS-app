import XCTest
@testable import DyorKit

/// A watched address (a session that can't sign) and the end of a session, read from the app's sources (build 23's QA):
/// Bridge opens no token picker for a watched address and shows no token list blank, Swap's review is off for it as
/// Profile's Send is, Profile's sign-out dialogs point at their buttons, and a sign-out closes what the account had open,
/// so the next session lands on Home.
final class WatchOnlySessionTests: XCTestCase {
    private func squeeze(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The text from `start` up to (not including) the first `end` after it.
    private func between(_ text: String, _ start: String, _ end: String) throws -> String {
        let from = try XCTUnwrap(text.range(of: start), start)
        let to = try XCTUnwrap(text.range(of: end, range: from.upperBound..<text.endIndex), end)
        return String(text[from.lowerBound..<to.lowerBound])
    }

    /// The bridge's backend lists its tokens for a wallet signed in to it only, so a watched address never has any: its
    /// chips open no picker, and a picker with nothing to list says why — for a watched address first, never "Loading" —
    /// rather than coming up blank with only Done.
    func testBridgeOpensNoPickerForAWatchedAddressAndNoBlankOne() throws {
        let bridge = try DocsLinksTests.appSource("Bridge/BridgeView.swift")
        let chips = squeeze(try between(bridge, "private func selectorStack(", "private func chainChip("))
        XCTAssertTrue(chips.contains("chainChip(chain) } .buttonStyle(.plain).disabled(chain.isMonad || !model.canEdit || !session.canSign)"))
        XCTAssertTrue(chips.contains("Button(action: tokenAction) { tokenChip(token) } .buttonStyle(.plain).disabled(!model.canEdit || !session.canSign)"))

        // Every token list: the cross-chain source list and one chain's (the source on Monad, and the destination).
        let source = squeeze(try between(bridge, "private var sourceAssetPicker: some View {", "private func tokenPicker("))
        XCTAssertTrue(source.contains(".overlay { if model.sourceAssets.isEmpty { tokensUnavailable } else if model.loadingBalances && model.sourceAssets.allSatisfy({ !model.held($0) }) {"))
        let chain = squeeze(try between(bridge, "private func tokenPicker(", "@ViewBuilder private var tokensUnavailable: some View {"))
        XCTAssertTrue(chain.contains("List(model.tokens(on: chain)) { token in"))
        XCTAssertTrue(chain.contains(".overlay { if model.tokens(on: chain).isEmpty { tokensUnavailable } }"))
        XCTAssertEqual(squeeze(bridge).components(separatedBy: "{ tokensUnavailable }").count - 1, 2)
        XCTAssertEqual(bridge.components(separatedBy: ".sheet(isPresented: $picking").count - 1, 2, "the two token pickers")
        XCTAssertEqual(bridge.components(separatedBy: ".sheet(isPresented: $showSourcePicker) { sourceAssetPicker }").count - 1, 1)

        let empty = squeeze(String(bridge[try XCTUnwrap(bridge.range(of: "@ViewBuilder private var tokensUnavailable: some View {")).lowerBound...]))
        XCTAssertTrue(empty.hasPrefix(#"@ViewBuilder private var tokensUnavailable: some View { if !session.canSign { ContentUnavailableView { Label("Watching this address", systemImage: "eye") } description: { Paragraph("#), "a watched address first")
        XCTAssertTrue(empty.contains(#"} else if model.loadingTokens { ProgressView("Loading…") } else {"#))
        XCTAssertTrue(empty.contains("if let error = model.loadError { Paragraph(verbatim: error) } else { Paragraph("))
        XCTAssertTrue(empty.contains(#"Button("Retry", systemImage: "arrow.clockwise") { Task { await model.load() } }"#))
        // Multi-line text in a Paragraph: in Korean it breaks between words only.
        XCTAssertFalse(try between(bridge, "@ViewBuilder private var tokensUnavailable: some View {", "\n    }\n").contains("Text("))
    }

    /// A watched address sees Swap's quotes but can't review a swap, which it couldn't sign: the button is off, and the
    /// footer says why in the words the Launch page and Perps use.
    func testSwapsReviewIsOffForAWatchedAddress() throws {
        let swap = try DocsLinksTests.appSource("Swap/SwapView.swift")
        let action = squeeze(try between(swap, "private var actionSection: some View {", "private var receiveSection: some View {"))
        XCTAssertTrue(action.contains("isDisabled: model.selectedQuote == nil || model.insufficient || !session.canSign) { reviewing = model.review }"))
        XCTAssertTrue(action.contains(#"} footer: { if !session.canSign { Text("Sign in to trade.")"#))
        XCTAssertEqual(swap.components(separatedBy: "reviewing = model.review").count - 1, 1, "Review opens from that button only")
        XCTAssertTrue(try DocsLinksTests.appSource("Launchpad/LaunchpadView.swift").contains(#"if !session.canSign { Text("Sign in to trade.") }"#))
    }

    /// iOS 26 shows a confirmation dialog as a popover pointing at the view it is attached to: on the list, Stop Watching's
    /// pointed at the top of the list (the Language row). Each dialog sits on its own button now, inside its section.
    func testProfilesDialogsPointAtTheirButtons() throws {
        let profile = try DocsLinksTests.appSource("Profile/ProfileView.swift")
        let body = squeeze(try between(profile, "    var body: some View {", "    private var avatarURL: URL? {"))
        XCTAssertEqual(body.components(separatedBy: ".confirmationDialog(").count - 1, 2)

        let signOut = try XCTUnwrap(body.range(of: #"Button(role: .destructive) { confirmSignOut = true } label: { Label(session.canSign ? "Sign Out" : "Stop Watching", systemImage: "rectangle.portrait.and.arrow.right") } .disabled(signingOut)"#))
        let signOutDialog = try XCTUnwrap(body.range(of: #".confirmationDialog(session.canSign ? "Sign out of DyorHQ?" : "Stop watching this address?", isPresented: $confirmSignOut, titleVisibility: .visible) {"#))
        let delete = try XCTUnwrap(body.range(of: "Button(role: .destructive) { showDeleteAccount = true }"))
        XCTAssertLessThan(signOut.upperBound, signOutDialog.lowerBound)
        XCTAssertLessThan(signOutDialog.upperBound, delete.lowerBound, "on the sign-out button, before the next row")
        XCTAssertTrue(body[signOut.upperBound..<signOutDialog.lowerBound].allSatisfy { $0 != "}" }, "nothing between the button and its dialog")

        let forget = try XCTUnwrap(body.range(of: #"Button(role: .destructive) { confirmForget = true } label: { Label("Forget This Device", systemImage: "iphone.slash") } .disabled(signingOut) .confirmationDialog("Forget this device?", isPresented: $confirmForget, titleVisibility: .visible) {"#))
        let forgetFooter = try XCTUnwrap(body.range(of: #"Paragraph("Removes this account from this iPhone."#))
        XCTAssertLessThan(forget.upperBound, forgetFooter.lowerBound)

        let list = String(body[try XCTUnwrap(body.range(of: ".listStyle(.insetGrouped)")).lowerBound...])
        XCTAssertFalse(list.contains(".confirmationDialog("), "nothing on the list itself")
        // What the dialogs do is as it was.
        XCTAssertTrue(body.contains("perplTrading.forget(address: address) } await session.signOut()"))
        XCTAssertTrue(body.contains("await AccountDeletion.eraseThisDevice(address: address, session: session, social: social, env: env)"))
    }

    /// The router is the app's one (`Router.shared`) and outlives a sign-out: what the account had open — a presented
    /// screen such as Profile, the menu, a tab, a screen asked for — closes when the session ends, so the next one starts on
    /// Home. A Moment link waiting for a sign-in still opens after it, and a banner's screen is the gate's to drop.
    func testASignOutClosesWhatTheAccountHadOpen() throws {
        let router = try DocsLinksTests.appSource("App/Router.swift")
        let end = squeeze(try between(router, "    func endSession() {", "\n    }\n"))
        for reset in ["menuOpen = false", "presented = nil", "tab = .home", "tradeMode = .swap", "pendingSwap = nil", "pendingPerpMarket = nil",
                      "pendingLaunch = nil", "pendingLaunchReference = nil", "pendingMoment = nil", "pendingMomentLink = nil"] {
            XCTAssertTrue(end.contains(reset), reset)
        }
        XCTAssertFalse(end.contains("pendingLink"), "a link that arrived signed out opens after the sign-in")
        XCTAssertFalse(end.contains("pendingNotificationRoute"))
        XCTAssertFalse(end.contains("linkHolds"), "counted by the sheets themselves")
        XCTAssertFalse(end.contains("period"), "the reporting period is a choice, not something open")

        let root = try DocsLinksTests.appSource("App/RootView.swift")
        let rootView = squeeze(try between(root, "struct RootView: View {", "extension RootView {"))
        XCTAssertTrue(rootView.contains(".onChange(of: session.state) { _, state in if state == .signedOut { router.endSession() } }"))
        XCTAssertEqual(squeeze(root).components(separatedBy: "endSession()").count - 1, 1)
        // Every way out of a session lands there: sign-out, account deletion and Forget This Device all end signed out.
        let presented = squeeze(try between(root, "struct MainTabView: View {", "\n}\n"))
        XCTAssertTrue(presented.contains(".fullScreenCover(item: $router.presented) { screen in"))
        XCTAssertTrue(presented.contains("case .profile: ProfileView(presented: true)"))
    }
}
