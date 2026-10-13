import AppKit

struct RemoveResult: Decodable, Sendable {
    let removed: Int
}

extension SettingsViewController {
    /// 仅删除本 App 索引与邮件副本; Thunderbird 数据保持只读.
    @objc
    func removeSelected() {
        guard !syncing, let window = view.window else { return }
        let ids = selected.filter { synced[$0] != nil }.sorted()
        guard !ids.isEmpty else { status.stringValue = "所选文件夹没有已同步数据"; return }
        let mails = ids.reduce(0) { $0 + (synced[$1]?.count ?? 0) }
        let gone = ids.filter { missing.contains($0) }.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 \(ids.count) 个文件夹的已同步数据（\(mails) 封）？"
        var notes = ["只删除本 App 的索引与邮件副本，Thunderbird 数据不变；重新同步可恢复 Thunderbird 中仍有正文的邮件。"]
        // IMAP 正文被 Thunderbird 清出缓存后, 本 App 副本是唯一本地正文.
        if ids.contains(where: { synced[$0]?.folder.imap == true }) {
            notes.append("IMAP 文件夹中 Thunderbird 已清出缓存的正文无法重新同步，需先在 Thunderbird 下载。")
        }
        if gone > 0 {
            notes.append("其中 \(gone) 个文件夹来源已不存在，删除后无法重新同步。")
        }
        alert.informativeText = notes.joined(separator: "\n")
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.remove(ids)
        }
    }

    private func remove(_ ids: [String]) {
        guard !syncing else { return }
        setBusy(true)
        status.stringValue = "正在删除已同步数据并回收空间…"
        syncTask = Task { [weak self] in
            guard let self else { return }
            var message: String
            do {
                let result = try await engine.call(
                    EngineRequest(operation: "remove", folders: ids),
                    as: RemoveResult.self
                )
                // 取消勾选, 避免下次「同步所选」重新导入.
                selected.subtract(ids)
                ConfigStore.update { $0.selectedSourceFolders = selected.sorted() }
                message = "已删除 \(result.removed) 个文件夹的同步数据"
            } catch { message = error.localizedDescription }
            setBusy(false)
            reload(message: message)
            libraryChanged?()
        }
    }
}
