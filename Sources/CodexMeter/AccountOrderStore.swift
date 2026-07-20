import Foundation

enum AccountOrderStore {
    private static let key = "account-order-v1"

    static func ordered<Value>(_ values: [Value], id: (Value) -> String) -> [Value] {
        let ids = values.map(id)
        let available = Set(ids)
        var seen = Set<String>()
        var order = storedOrder.filter { available.contains($0) && seen.insert($0).inserted }
        order.append(contentsOf: ids.filter { seen.insert($0).inserted })
        if order != storedOrder { set(order) }

        let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        return values.sorted { (positions[id($0)] ?? .max) < (positions[id($1)] ?? .max) }
    }

    static func set(_ accountIDs: [String]) {
        UserDefaults.standard.set(accountIDs, forKey: key)
    }

    static func removeAll() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static var storedOrder: [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
}
