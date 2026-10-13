import Foundation

/// 用户可理解的选项: config.jsonc, 带逐键说明, 可手工编辑 (重启生效), 界面操作时整文件重写.
/// 新增键: 加属性 (带默认值) + `ConfigStore.configNotes` 说明.
struct AppConfig: Codable, Equatable {
    /// 主界面文字字号 (pt).
    var fontSize = 12.0
    /// Thunderbird profiles.ini 所在目录。
    var thunderbirdRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Thunderbird")
        .path
}

/// 界面状态: state.json, App 写入.
struct AppState: Codable, Equatable {
    var window: WindowFrame?
    var selectedSourceFolders: [String] = []
    var searchFolder: String = ""
    var searchQuery: String = ""
}

struct WindowFrame: Codable, Equatable {
    var minX: Double
    var minY: Double
    var width: Double
    var height: Double
}

/// `~/.config/<ConfigStore.appName>/`; 所有实例共用同一配置目录.
/// - `config.jsonc`: 界面选项; `config.default.jsonc`: 全部键默认值, 每次启动刷新, 仅供查阅.
/// - `state.json`: 界面状态.
@MainActor
enum ConfigStore {
    /// 配置目录名 + 日志前缀.
    nonisolated static let appName = "jj-email-search"

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/\(appName)", isDirectory: true)

    private static var configFile = PersistedFile(
        url: directory.appendingPathComponent("config.jsonc"), defaults: AppConfig(), jsonc: true,
        render: { try encodeConfig($0) }
    )
    private static var stateFile = PersistedFile(
        url: directory.appendingPathComponent("state.json"), defaults: AppState(), jsonc: false,
        render: { try encode($0) }
    )

    static var config: AppConfig {
        configFile.value
    }

    static var state: AppState {
        stateFile.value
    }

    /// 窗口副标题提示.
    static var warnings: String {
        [configFile.failure, stateFile.failure].compactMap(\.self).joined(separator: "; ")
    }

    /// 读取两份文件; 刷新默认模板; 缺失的 config.jsonc 以默认值新建.
    static func load() {
        configFile.load()
        stateFile.load()
        configFile.update { _ in }
        do {
            let template = try encodeConfig(AppConfig())
            let url = directory.appendingPathComponent("config.default.jsonc")
            if (try? Data(contentsOf: url)) != template {
                try write(template, to: url)
            }
        } catch {
            NSLog("\(ConfigStore.appName): write config.default.jsonc failed: \(error)")
        }
    }

    static func updateConfig(_ change: (inout AppConfig) -> Void) {
        configFile.update(change)
    }

    static func update(_ change: (inout AppState) -> Void) {
        stateFile.update(change)
    }

    fileprivate static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    fileprivate static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    /// 逐键插入中文说明; 数值取自模型.
    private static func encodeConfig(_ config: AppConfig) throws -> Data {
        let text = try String(bytes: encode(config), encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n").map { line -> String in
            let parts = line.split(separator: "\"", maxSplits: 2)
            guard parts.count == 3, let note = configNotes[String(parts[1])] else { return line }
            let indent = String(line.prefix(while: { $0 == " " }))
            return "\(indent)// \(note)\n\(line)"
        }
        let header = "// 界面操作时由 App 重写本文件; 手工修改后重启生效; 缺失键 / null 取默认值.\n"
        return Data((header + lines.joined(separator: "\n")).utf8)
    }

    private static let configNotes: [String: String] = [
        "fontSize": "界面字号 (pt), 10–18; 其他值取 12.",
        "thunderbirdRoot": "Thunderbird profiles.ini 所在目录; 仅读取本地邮件."
    ]
}

/// 一份 JSON / JSONC 文件: 以默认值为底读取, 变化时整文件重写; 解析失败停写, 保留原文件待人工修正.
@MainActor
private struct PersistedFile<Value: Codable & Equatable> {
    let url: URL
    let jsonc: Bool
    let render: (Value) throws -> Data
    private(set) var value: Value
    private(set) var failure: String?
    private var savedData: Data?

    init(url: URL, defaults: Value, jsonc: Bool, render: @escaping (Value) throws -> Data) {
        self.url = url
        self.jsonc = jsonc
        self.render = render
        value = defaults
    }

    mutating func load() {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            let data = try Data(contentsOf: url)
            value = try decode(data, defaults: value)
            savedData = data
        } catch {
            // 副标题与标题栏按钮同行: 只放短提示, 详情进日志.
            failure = "\(url.lastPathComponent) 解析失败, 本次不保存"
            NSLog("\(ConfigStore.appName): \(url.path): \(error)")
        }
    }

    mutating func update(_ change: (inout Value) -> Void) {
        change(&value)
        guard failure == nil else { return }
        do {
            let data = try render(value)
            guard data != savedData else { return }
            try ConfigStore.write(data, to: url)
            savedData = data
        } catch {
            NSLog("\(ConfigStore.appName): write \(url.path) failed: \(error)")
        }
    }

    /// 缺失键或 null 取默认值 (新增字段不破坏旧文件), 其余按类型解码; jsonc 按 JSON5 解析 (注释 + 尾逗号).
    private func decode(_ data: Data, defaults: Value) throws -> Value {
        let options: JSONSerialization.ReadingOptions = jsonc ? .json5Allowed : []
        guard let override = try JSONSerialization.jsonObject(with: data, options: options) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        let base = try JSONSerialization.jsonObject(with: JSONEncoder().encode(defaults))
        let merged = try JSONSerialization.data(withJSONObject: Self.merge(base, override))
        return try JSONDecoder().decode(Value.self, from: merged)
    }

    private static func merge(_ base: Any, _ override: Any) -> Any {
        if override is NSNull {
            return base
        }
        guard var result = base as? [String: Any], let values = override as? [String: Any] else { return override }
        for (key, value) in values {
            result[key] = result[key].map { merge($0, value) } ?? value
        }
        return result
    }
}
