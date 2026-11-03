import XCTest

/// Which share targets get the card picture and which only the message (Shared/SharePlan.swift).
final class SharePlanTests: XCTestCase {
    func testWhatsAppGetsTheMessageOnly() {
        XCTAssertEqual(SharePlan.content(forServiceTitle: "WhatsApp"), .messageOnly)
        XCTAssertEqual(SharePlan.content(forServiceTitle: "whatsapp"), .messageOnly, "any case")
        XCTAssertEqual(SharePlan.content(forServiceTitle: "WhatsApp Business"), .messageOnly)
    }

    func testOtherTargetsGetPictureAndMessage() {
        for title in ["Messages", "Nachrichten", "Mail", "AirDrop", "Notes", "Telegram", "Slack", ""] {
            XCTAssertEqual(SharePlan.content(forServiceTitle: title), .pictureAndMessage, title)
        }
    }
}
