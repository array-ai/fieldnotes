import Foundation

extension String {
    public func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}
