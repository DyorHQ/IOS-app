import Foundation

/// What the app's notification about a perp order says. Perpl acknowledging an order is not a fill: a market order is
/// "submitted" until a position read sees it filled, and a limit order is "placed" on the book. Only a position that
/// opened or grew (`PerpsView.detectFills`) says "filled".
public enum PerpOrderNotice: Hashable, Sendable, CaseIterable {
    /// Perpl acknowledged a market order; nothing is known to have filled yet.
    case submitted
    /// Perpl acknowledged a limit order, which rests on the book.
    case placed
    /// A position read saw the position open or grow.
    case filled

    /// The notice for Perpl's acknowledgement of an order of `kind`: "submitted" for a market order, "placed" for a
    /// limit order, never "filled".
    public init(acknowledged kind: OrderKind) {
        switch kind {
        case .market: self = .submitted
        case .limit: self = .placed
        }
    }

    public var title: String {
        switch self {
        case .submitted: return L10n.string(LocalizedStringResource("Order submitted", bundle: L10n.kit, comment: "A notification's title: Perpl acknowledged a market order, which may not have filled yet."))
        case .placed: return L10n.string(LocalizedStringResource("Order placed", bundle: L10n.kit, comment: "A notification's title: Perpl acknowledged a limit order, which now rests on the order book."))
        case .filled: return L10n.string(LocalizedStringResource("Order filled", bundle: L10n.kit, comment: "A notification's title: a position opened or grew, so the order was filled (executed)."))
        }
    }
}
