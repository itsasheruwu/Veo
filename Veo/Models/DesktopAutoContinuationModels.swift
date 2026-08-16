import Foundation

enum DesktopAutoContinuationWakePolicy: String, CaseIterable, Identifiable, Codable {
    case nextLaunch
    case wakeQuietly

    var id: Self { self }

    var title: String {
        switch self {
        case .nextLaunch: return "Resume next launch"
        case .wakeQuietly: return "Wake Veo quietly"
        }
    }
}

enum DesktopAutoContinuationStatus: String, Codable {
    case waiting
    case dispatching
    case blocked
    case completed
}

struct DesktopAutoContinuationJob: Identifiable, Codable, Hashable {
    let id: String
    let uiThreadID: String
    let runtimeThreadID: String
    var failedTurnID: String
    var resetAt: Date?
    let continuationClientID: String
    let accessMode: DesktopAccessMode
    let model: String?
    let reasoningEffort: String?
    let serviceTier: String?
    let interactionMode: DesktopInteractionMode
    let routingMode: DesktopModelRoutingMode
    let autoRoutePlan: DesktopAutoRoutePlan?
    var isEnabled: Bool
    var status: DesktopAutoContinuationStatus
    var detail: String?
    var continuationTurnID: String?
    let createdAt: Date

    var dispatchAt: Date? { resetAt?.addingTimeInterval(8) }

    private enum CodingKeys: String, CodingKey {
        case id
        case uiThreadID
        case runtimeThreadID
        case failedTurnID
        case resetAt
        case continuationClientID
        case accessMode
        case model
        case reasoningEffort
        case serviceTier
        case interactionMode
        case routingMode
        case autoRoutePlan
        case isPlanMode
        case isEnabled
        case status
        case detail
        case continuationTurnID
        case createdAt
    }

    init(
        id: String,
        uiThreadID: String,
        runtimeThreadID: String,
        failedTurnID: String,
        resetAt: Date?,
        continuationClientID: String,
        accessMode: DesktopAccessMode,
        model: String?,
        reasoningEffort: String?,
        serviceTier: String?,
        interactionMode: DesktopInteractionMode,
        routingMode: DesktopModelRoutingMode,
        autoRoutePlan: DesktopAutoRoutePlan?,
        isEnabled: Bool,
        status: DesktopAutoContinuationStatus,
        detail: String?,
        continuationTurnID: String?,
        createdAt: Date
    ) {
        self.id = id
        self.uiThreadID = uiThreadID
        self.runtimeThreadID = runtimeThreadID
        self.failedTurnID = failedTurnID
        self.resetAt = resetAt
        self.continuationClientID = continuationClientID
        self.accessMode = accessMode
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.interactionMode = interactionMode
        self.routingMode = routingMode
        self.autoRoutePlan = autoRoutePlan
        self.isEnabled = isEnabled
        self.status = status
        self.detail = detail
        self.continuationTurnID = continuationTurnID
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        uiThreadID = try container.decode(String.self, forKey: .uiThreadID)
        runtimeThreadID = try container.decode(String.self, forKey: .runtimeThreadID)
        failedTurnID = try container.decode(String.self, forKey: .failedTurnID)
        resetAt = try container.decodeIfPresent(Date.self, forKey: .resetAt)
        continuationClientID = try container.decode(String.self, forKey: .continuationClientID)
        accessMode = try container.decode(DesktopAccessMode.self, forKey: .accessMode)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        serviceTier = try container.decodeIfPresent(String.self, forKey: .serviceTier)
        if let savedMode = try container.decodeIfPresent(
            DesktopInteractionMode.self,
            forKey: .interactionMode
        ) {
            interactionMode = savedMode
        } else {
            interactionMode = try container.decodeIfPresent(Bool.self, forKey: .isPlanMode) == true
                ? .plan
                : .agentic
        }
        routingMode = try container.decodeIfPresent(DesktopModelRoutingMode.self, forKey: .routingMode) ?? .direct
        autoRoutePlan = try container.decodeIfPresent(DesktopAutoRoutePlan.self, forKey: .autoRoutePlan)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        status = try container.decode(DesktopAutoContinuationStatus.self, forKey: .status)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        continuationTurnID = try container.decodeIfPresent(String.self, forKey: .continuationTurnID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(uiThreadID, forKey: .uiThreadID)
        try container.encode(runtimeThreadID, forKey: .runtimeThreadID)
        try container.encode(failedTurnID, forKey: .failedTurnID)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
        try container.encode(continuationClientID, forKey: .continuationClientID)
        try container.encode(accessMode, forKey: .accessMode)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(serviceTier, forKey: .serviceTier)
        try container.encode(interactionMode, forKey: .interactionMode)
        try container.encode(routingMode, forKey: .routingMode)
        try container.encodeIfPresent(autoRoutePlan, forKey: .autoRoutePlan)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encodeIfPresent(continuationTurnID, forKey: .continuationTurnID)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

enum DesktopAutoContinuationPreferences {
    static let enabledByDefaultKey = "VeoDesktop.autoContinueUsageLimits"
    static let wakePolicyKey = "VeoDesktop.autoContinueWakePolicy"

    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            enabledByDefaultKey: false,
            wakePolicyKey: DesktopAutoContinuationWakePolicy.nextLaunch.rawValue,
        ])
    }
}
