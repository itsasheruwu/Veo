import Foundation

struct DesktopWorktree: Identifiable, Sendable {
    let path: String
    let branch: String?
    var id: String { path }
}
