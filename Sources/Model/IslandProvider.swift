import Foundation

enum IslandProvider: String, CaseIterable, Identifiable, Codable {
    case claude, codex, grok, antigravity, cursor

    var id: String { rawValue }
    var name: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        case .cursor: return "Cursor"
        }
    }
    var usesLegacyUsage: Bool { self == .claude || self == .codex }

    var connectTitle: String {
        switch self {
        case .grok: return "Sign in with Grok CLI"
        case .antigravity: return "Open agy CLI"
        case .cursor: return "Open Cursor"
        default: return "Connect"
        }
    }

    var signInAgainTitle: String {
        switch self {
        case .grok: return "Sign in again…"
        case .antigravity: return "Open agy CLI"
        case .cursor: return "Open Cursor"
        default: return "Sign in again…"
        }
    }

    var disconnectedMessage: String {
        switch self {
        case .grok: return "Sign in with Grok CLI to connect your subscription."
        case .antigravity: return "Sign in with agy CLI to connect your subscription."
        case .cursor: return "Open Cursor and sign in to connect your subscription."
        default: return "Sign in to connect your subscription."
        }
    }

    var restoreMessage: String {
        switch self {
        case .grok: return "Run grok login, then refresh the connection."
        case .antigravity: return "Open agy CLI to restore your session, then refresh the connection."
        case .cursor: return "Open Cursor so it can refresh its session, then refresh the connection."
        default: return "Sign in, then refresh the connection."
        }
    }

    var fetchErrorMessage: String {
        switch self {
        case .grok: return "Could not read Grok usage. Try refreshing the connection."
        case .antigravity: return "Could not read Antigravity usage. Check your agy CLI login, then refresh."
        case .cursor: return "Could not read Cursor usage. Open Cursor, then refresh the connection."
        default: return "Could not read usage. Try refreshing the connection."
        }
    }
}
