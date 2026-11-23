import Foundation

enum SecureInputHolder: Equatable {
    case known(pid_t?)
    case unavailable

    var processID: pid_t? {
        guard case let .known(processID) = self else { return nil }
        return processID
    }
}

struct SecureInputDecision: Equatable {
    enum Rule: String {
        case secureTextField
        case foregroundHolder
        case accessibilityFallback
        case holderQueryFallback
        case ordinaryFocus
    }

    let isSecure: Bool
    let rule: Rule

    static func evaluate(
        focusedElementIsSecure: Bool?,
        secureInputEnabled: Bool,
        holder: SecureInputHolder,
        frontmostProcessID: pid_t?
    ) -> SecureInputDecision {
        if focusedElementIsSecure == true {
            return SecureInputDecision(isSecure: true, rule: .secureTextField)
        }
        if secureInputEnabled, let holderProcessID = holder.processID,
           holderProcessID == frontmostProcessID {
            return SecureInputDecision(isSecure: true, rule: .foregroundHolder)
        }
        if focusedElementIsSecure == nil {
            return SecureInputDecision(isSecure: secureInputEnabled, rule: .accessibilityFallback)
        }
        if holder == .unavailable {
            return SecureInputDecision(isSecure: secureInputEnabled, rule: .holderQueryFallback)
        }
        return SecureInputDecision(isSecure: false, rule: .ordinaryFocus)
    }
}
