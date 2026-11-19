import Foundation

struct DesktopTurnPresentation: Codable, Equatable, Identifiable {
    let id: String
    var startedAt: Date?
    var completedAt: Date?
    var status: String?
    var diff: DesktopTurnDiff?
    var steers: [String: Date]?

    static func eventDate(_ value: Double?) -> Date? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }

    func elapsed(until end: Date) -> String? {
        guard let startedAt, end >= startedAt else { return nil }
        let seconds = Int(end.timeIntervalSince(startedAt))
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
    }
}
