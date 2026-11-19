import Foundation

struct DesktopSideChatExchange: Identifiable {
    let id = UUID()
    let question: String
    var answer: String?
}

struct DesktopSideChatSession {
    var exchanges: [DesktopSideChatExchange] = []
    var isRunning = false
    var error: String?
}
