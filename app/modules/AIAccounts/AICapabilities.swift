import Foundation

public enum AICapability: String, CaseIterable {
    case terminal, web, screen, input, apps, chrome

    fileprivate var defaultRule: CapabilityRule {
        switch self {
        case .terminal, .web: return .on
        case .screen, .input, .apps, .chrome: return .off
        }
    }
}

public enum CapabilityRule: String, CaseIterable {
    case off, ask, on
}

public enum AICapabilities {
    public static func rule(_ account: Account, _ capability: AICapability) -> CapabilityRule {
        let saved = UserDefaults.app.string(forKey: key(account, capability))
        return saved.flatMap(CapabilityRule.init(rawValue:)) ?? capability.defaultRule
    }

    public static func set(_ rule: CapabilityRule, for account: Account, _ capability: AICapability) {
        UserDefaults.app.set(rule.rawValue, forKey: key(account, capability))
    }

    private static func key(_ account: Account, _ capability: AICapability) -> String {
        "aiCapabilities.\(capability.rawValue).\(account.id)"
    }
}
