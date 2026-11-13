import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let now = Date()
let store = ChatCache(directory: root, maxCount: 2)
let message = CachedMessage(role: "user", text: "你好")
let first = UUID().uuidString, second = UUID().uuidString, third = UUID().uuidString
try store.save(id: "../../escape", title: "invalid", messages: [message])
let initiallyEmpty = try store.list().isEmpty
assert(initiallyEmpty)
try store.save(id: first, title: "one", messages: [message], now: now)
try store.save(id: second, title: "two", messages: [message], now: now.addingTimeInterval(1))
try store.save(id: third, title: "three", messages: [message], now: now.addingTimeInterval(2))
let list = try store.list(now: now.addingTimeInterval(3))
assert(list.count == 2 && list[0].id == third.lowercased())
assert(!list.contains { $0.id == first.lowercased() })
try store.save(id: third, title: "changed", messages: [CachedMessage(role: "assistant", text: "updated")], now: now.addingTimeInterval(4))
let updated = try store.list(now: now.addingTimeInterval(5))
assert(updated.count == 2 && updated[0].messages[0].text == "updated")
let expired = try store.list(now: now.addingTimeInterval(8 * 86400)).isEmpty
assert(expired)
try store.save(id: first, title: "large", messages: (0..<100).map { _ in CachedMessage(role: "assistant", text: String(repeating: "字", count: 30000)) })
let bounded = try store.list()
assert(bounded.count == 1 && bounded[0].messages.count <= 80)
assert(bounded[0].messages.allSatisfy { $0.text.count <= 12000 })
let bytes = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).reduce(0) { sum, file in sum + (try Data(contentsOf: file).count) }
assert(bytes <= 200 * 1024)
let tiny = ChatCache(directory: root, maxBytes: 1)
let pruned = try tiny.list().isEmpty
assert(pruned)
try store.clear()
let cleared = try store.list().isEmpty
assert(cleared)
print("Cache tests passed: path safety, update, retention, age expiry, per-file and total byte bounds, clear")
