import Foundation

struct CachedMessage: Codable, Equatable {
    let role: String
    let text: String
}
struct CachedChat: Codable {
    let id: String
    let title: String
    let savedAt: Date
    let messages: [CachedMessage]
}

// Access only from the controller's serial cache queue. No network requests or credentials.
final class ChatCache {
    let directory: URL
    let maxCount: Int
    let maxBytes: Int
    let ttl: TimeInterval
    init(directory: URL, maxCount: Int = 20, maxBytes: Int = 10 * 1024 * 1024, ttl: TimeInterval = 7 * 86400) {
        self.directory = directory
        self.maxCount = maxCount
        self.maxBytes = maxBytes
        self.ttl = ttl
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
        #endif
    }
    func save(id: String, title: String, messages: [CachedMessage], now: Date = Date()) throws {
        guard let uuid = UUID(uuidString: id) else { return }
        var safe = messages.suffix(80).filter { ["user", "assistant"].contains($0.role) && !$0.text.isEmpty }
            .map { CachedMessage(role: $0.role, text: String($0.text.prefix(12000))) }
        guard !safe.isEmpty else { return }
        try prepare()
        var data: Data
        repeat {
            let item = CachedChat(id: uuid.uuidString.lowercased(), title: String(title.prefix(100)), savedAt: now, messages: safe)
            data = try JSONEncoder().encode(item)
            if data.count <= 200 * 1024 { break }
            safe.removeFirst()
        } while !safe.isEmpty
        guard !safe.isEmpty else { return }
        let file = directory.appendingPathComponent(uuid.uuidString.lowercased()).appendingPathExtension("json")
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        _ = try list(now: now)
    }
    func list(now: Date = Date()) throws -> [CachedChat] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var records: [(CachedChat, URL, Int)] = []
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) where file.pathExtension == "json" {
            // A locked protected file must never be treated as corrupt and deleted.
            let data = try Data(contentsOf: file)
            guard let item = try? JSONDecoder().decode(CachedChat.self, from: data), UUID(uuidString: item.id) != nil,
                  now.timeIntervalSince(item.savedAt) <= ttl else {
                try FileManager.default.removeItem(at: file)
                continue
            }
            records.append((item, file, data.count))
        }
        records.sort { $0.0.savedAt > $1.0.savedAt }
        var bytes = 0
        var kept: [CachedChat] = []
        for (item, file, size) in records {
            if kept.count < maxCount && bytes + size <= maxBytes {
                kept.append(item); bytes += size
            } else { try FileManager.default.removeItem(at: file) }
        }
        return kept
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
