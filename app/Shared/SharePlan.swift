import Foundation

/// What a share target gets from the share menu: the card picture plus the message, or the message alone.
///
/// WhatsApp for Mac takes either a picture or text, never both: with the card attached it dropped the message and with
/// it the join link (Valentin, 03.11.2026, build 34). It gets the message alone; the link preview of tokenmaccer.app
/// (og-invite.jpg on /join/ links, og.jpg otherwise) still shows a picture, and the link stays clickable.
enum SharePlan: Equatable {
    case pictureAndMessage
    case messageOnly

    /// Decided by the share target's title as the menu shows it (a brand name, the same in every language).
    static func content(forServiceTitle title: String) -> SharePlan {
        title.range(of: "whatsapp", options: [.caseInsensitive, .diacriticInsensitive]) != nil
            ? .messageOnly : .pictureAndMessage
    }
}
