import Foundation

/// Lightweight description of a running macOS app. Keeps AppKit types out of MacAgentCore.
public struct RunningApp: Codable, Sendable, Equatable {
    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}
