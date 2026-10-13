import Foundation

struct MailFolder: Codable, Sendable, Equatable {
    let id: String
    let account: String
    let name: String
    let profile: String
    let store: String
    let summary: String
    let imap: Bool
    let maildir: Bool
}

struct FolderState: Codable, Sendable {
    let folder: MailFolder
    let total: Int
    let count: Int
    let unavailable: Int
    let updated: Int
    let syncedAt: Double
    enum CodingKeys: String, CodingKey {
        case folder, total, count, unavailable, updated
        case syncedAt = "synced_at"
    }
}

struct LibraryState: Decodable, Sendable {
    let folders: [FolderState]
    let count: Int
}

struct MailItem: Codable, Sendable {
    let id: String
    let folder: String
    let account: String
    let folderName: String
    let subject: String
    let sender: String
    let recipients: String
    let date: Double
    let flags: UInt64
    let size: Int
    let complete: Int
    let attachments: Int
    enum CodingKeys: String, CodingKey {
        case id, folder, account, subject, sender, recipients, date, flags, size, complete, attachments
        case folderName = "folder_name"
    }
}

struct SearchResult: Decodable, Sendable {
    let items: [MailItem]
    let elapsedMs: Double
    let count: Int
    enum CodingKeys: String, CodingKey {
        case items, count
        case elapsedMs = "elapsed_ms"
    }
}

struct MailAttachment: Decodable, Sendable {
    let index: Int
    let name: String
    let size: Int
    let available: Bool
}

struct MailPreview: Decodable, Sendable {
    let subject: String
    let sender: String
    let recipients: String
    let body: String
    let ownBody: String
    let quoted: Bool
    let attachments: [MailAttachment]
    let complete: Bool
    enum CodingKeys: String, CodingKey {
        case subject, sender, recipients, body, quoted, attachments, complete
        case ownBody = "own_body"
    }
}

struct SyncResult: Decodable, Sendable {
    let folders: [FolderState]
    let elapsedMs: Double
    enum CodingKeys: String, CodingKey {
        case folders
        case elapsedMs = "elapsed_ms"
    }
}

struct EngineProgress: Decodable, Sendable {
    let current: Int
    let total: Int
    let imported: Int
    let bytes: Int
}

struct EmptyResult: Decodable, Sendable {
}

struct EngineRequest: Encodable, Sendable {
    let operation: String
    var root: String?
    var folders: [String]?
    var query: String?
    var field: String?
    var id: String?
    var path: String?
    var attachment: Int?
    enum CodingKeys: String, CodingKey {
        case operation = "op"
        case root, folders, query, field, id, path, attachment
    }
}

private final class InvocationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }; return cancelled
    }
}

private struct EngineEnvelope<Value: Decodable>: Decodable {
    let succeeded: Bool
    let data: Value?
    let error: String?
    enum CodingKeys: String, CodingKey {
        case succeeded = "ok"
        case data, error
    }
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? {
        message
    }
}

/// All native work is serialized off the main actor. Cancellation/progress use
/// independent Rust atomics and never wait on the indexing mutex.
final class MailEngine: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    private let queue = DispatchQueue(label: "com.yigegongjiang.jj-email-search.engine", qos: .userInitiated)

    init(directory: URL) throws {
        guard let handle = directory.path.withCString({ jj_engine_open($0) }) else {
            throw EngineError(message: "无法初始化邮件引擎")
        }
        self.handle = handle
    }

    deinit { jj_engine_close(handle) }

    func call<Value: Decodable & Sendable>(_ request: EngineRequest, as _: Value.Type) async throws -> Value {
        try Task.checkCancellation()
        let payload = try JSONEncoder().encode(request)
        let cancellation = InvocationCancellation()
        if request.operation == "sync" {
            jj_engine_begin_sync(handle)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard let input = String(data: payload, encoding: .utf8),
                              let output = input.withCString({ jj_engine_call(handle, $0) }) else {
                            throw EngineError(message: "邮件引擎没有返回结果")
                        }
                        defer { jj_engine_free_string(output) }
                        let data = Data(bytes: output, count: strlen(output))
                        let decoder = JSONDecoder()
                        let envelope = try decoder.decode(EngineEnvelope<Value>.self, from: data)
                        guard envelope.succeeded, let value = envelope.data else {
                            throw EngineError(message: envelope.error ?? "未知引擎错误")
                        }
                        continuation.resume(returning: value)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { [self] in
            cancellation.cancel()
            if request.operation == "sync" {
                cancel()
            }
        }
    }

    func cancel() {
        jj_engine_cancel(handle)
    }

    func progress() -> EngineProgress? {
        guard let output = jj_engine_progress(handle) else { return nil }
        defer { jj_engine_free_string(output) }
        return try? JSONDecoder().decode(EngineProgress.self, from: Data(bytes: output, count: strlen(output)))
    }
}
