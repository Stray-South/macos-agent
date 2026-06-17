import Foundation

extension Duration {
    /// Whole milliseconds, including sub-second precision.
    /// `components.seconds` is an Int64 of whole seconds and discards `.attoseconds`,
    /// so naive `seconds * 1000` arithmetic reports 0 for any duration under one second.
    /// This helper preserves the sub-second component.
    public var milliseconds: Int64 {
        let parts = components
        return parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
    }
}
