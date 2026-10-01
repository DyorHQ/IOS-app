import XCTest
@testable import DyorKit

/// The price alerts in the app: the target field is read with `PriceAlertTarget.parse` (the amount fields' parser),
/// it is wide enough for a dust target, and the list and the notification show prices in the one style.
final class PriceAlertWiringTests: XCTestCase {
    /// The app reads the target with `PriceAlertTarget.parse`, never `Double(targetText)`, and the list and the
    /// notification show it in the one price style.
    func testTargetParsingAndDisplay() throws {
        let alerts = try DocsLinksTests.appSource("Wallet/PriceAlerts.swift")
        XCTAssertTrue(alerts.contains("private var target: Double? { PriceAlertTarget.parse(targetText) }"))
        XCTAssertFalse(alerts.contains("Double(targetText)"))
        XCTAssertTrue(alerts.contains("\\(PriceFormat.usdPrice(alert.target))"))
        XCTAssertTrue(alerts.contains(".accessibilityLabel(\"\\(alert.above ? \"Above\" : \"Below\") \\(PriceFormat.spoken(alert.target))\")"))
        XCTAssertTrue(alerts.contains(".frame(maxWidth: 220).layoutPriority(1)"), "the field widens for a dust target")
        XCTAssertTrue(alerts.contains("Text(\"Target\").fixedSize()"), "the wider field never cuts the Target label short")
        XCTAssertTrue(alerts.contains("Text(\"USD\").foregroundStyle(.secondary).fixedSize()"), "nor the USD label")
        XCTAssertFalse(alerts.contains("minWidth: 120"), "no minimum width that pushes the row past the edge at large text sizes")
        XCTAssertFalse(alerts.contains("NumberStyle."), "no second number style on the alerts screen")
        let notifications = try DocsLinksTests.appSource("Wallet/Notifications.swift")
        XCTAssertTrue(notifications.contains("is now \\(PriceFormat.usdPrice(price)) — \\(above ? \"above\" : \"below\") your \\(PriceFormat.usdPrice(target)) target."))
    }
}
