import Foundation

/// An embedding application's authorization boundary, independent of model-supplied arguments.
/// Omitted models and fields are unavailable, including through filters and audit history.
public struct LatticeReadPolicy: Sendable {
    public let permittedFields: [String: Set<String>]
    /// Host-owned container identities, independent of model-supplied predicates.
    /// Current rows in mapped models must match these values. When supplied,
    /// audit history is available only for mapped models with provable identities.
    /// An empty expected value accepts a legacy absent/NULL/empty identity field.
    /// Row-scoped projections expose scalar properties only; relationship targets
    /// and counts need separate authorization and are not inferred from the root.
    public let requiredRowValues: [String: [String: String]]?
    public init(permittedFields: [String: Set<String>], requiredRowValues: [String: [String: String]]? = nil) {
        self.permittedFields = permittedFields
        self.requiredRowValues = requiredRowValues
    }
    public func allows(model: String) -> Bool { permittedFields[model] != nil }
    public func allows(model: String, field: String) -> Bool {
        guard let fields = permittedFields[model] else { return false }
        return field == "id" || field == "globalId" || fields.contains(field)
    }
}
