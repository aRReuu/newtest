import Foundation

/// Shared V3 notification identifiers. The earlier smart prefix remains
/// recognized only to migrate/cancel notifications already queued by the pilot.
public enum ReviewReminderIdentifiers {
    public static let namespace = "impress.v3."
    public static let smartPrefix = namespace + "smart."
    public static let habit = namespace + "habit"
    public static let legacySmartPrefix = "impress.smart."

    public static func smart(for fireAt: Date) -> String {
        "\(smartPrefix)\(Int(fireAt.timeIntervalSince1970))"
    }

    public static func isManaged(_ identifier: String) -> Bool {
        identifier.hasPrefix(namespace) || identifier.hasPrefix(legacySmartPrefix)
    }
}
