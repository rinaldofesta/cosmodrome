import Foundation

public enum AgentState: String, Codable, Sendable {
    case inactive
    case working
    case needsInput
    case error
}
