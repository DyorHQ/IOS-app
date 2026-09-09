import SwiftUI

/// Semantic colors from the asset catalog (defined light + dark per the DyorHQ design system). The accent is the
/// text/canvas pair inverted; positive/negative/attention are the only status hues and always ship with a sign or
/// word beside them, never color alone.
extension Color {
    static let accent = Color("AccentColor")
    static let positive = Color("Positive")
    static let negative = Color("Negative")
    static let attention = Color("Attention")
}

extension ShapeStyle where Self == Color {
    static var positive: Color { .positive }
    static var negative: Color { .negative }
    static var attention: Color { .attention }
}
