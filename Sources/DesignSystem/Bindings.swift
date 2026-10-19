import SwiftUI

public extension Binding where Value: Collection, Value: ExpressibleByArrayLiteral, Value: Sendable {
    /// `true` while the collection is non-empty; setting `false` empties it. Drives confirmation dialogs from a
    /// "pending" list (`isPresented: $pendingDelete.isPresent`).
    var isPresent: Binding<Bool> {
        Binding<Bool>(get: { !wrappedValue.isEmpty }, set: { if !$0 { wrappedValue = [] } })
    }
}
