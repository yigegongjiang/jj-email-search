import AppKit

@MainActor
final class SettingsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let engine: MailEngine
    var libraryChanged: (() -> Void)?
    private let table = AccessibleTable()
    private let source = label("", identifier: "thunderbird-root")
    let status = label("读取 Thunderbird 文件夹…", identifier: "sync-status")
    private let progress = NSProgressIndicator()
    private var folders: [MailFolder] = []
    var selected: Set<String> = []
    /// 已同步文件夹 (引擎 manifest); `missing` = 已同步但当前来源中不存在, 只能删除.
    var synced: [String: FolderState] = [:]
    var missing: Set<String> = []
    var syncing = false
    private var restoringSelection = false
    var syncTask: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var syncButton: NSButton?
    private var refreshButton: NSButton?
    private var rootButton: NSButton?
    private var removeButton: NSButton?
    private var cancelButton: NSButton?

    init(engine: MailEngine) {
        self.engine = engine; super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 850, height: 620))
        selected = Set(ConfigStore.state.selectedSourceFolders)
        source.stringValue = "只读来源：\(ConfigStore.config.thunderbirdRoot)"
        source.font = .systemFont(ofSize: 11)
        table.dataSource = self; table.delegate = self
        table.rowHeight = 25
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.setAccessibilityIdentifier("source-folders")
        for (id, title, width) in [("account", "账户", 250.0), ("folder", "文件夹", 400.0), ("synced", "已同步", 130.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title; column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.documentView = table; scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        let hint = label("手动同步：关闭 Thunderbird → 只读快照 → 增量导入。按 Command 多选账户／文件夹；「删除已同步」只删除本 App 数据。")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11)
        progress.style = .bar; progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.setAccessibilityIdentifier("sync-progress")
        // 仅同步期间显示; 空闲时的空进度条易被误读为卡住的任务.
        progress.isHidden = true
        let stack = NSStackView(views: [source, hint, scroll, progress, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        for child in [source, hint, scroll, progress, status] {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
            source.heightAnchor.constraint(equalToConstant: 16), hint.heightAnchor.constraint(equalToConstant: 16),
            status.heightAnchor.constraint(equalToConstant: 18), progress.heightAnchor.constraint(equalToConstant: 8)
        ])
        refresh()
    }

    func installTitlebar(in window: NSWindow) {
        let root = NSButton(title: "选择来源", target: self, action: #selector(chooseRoot))
        root.setAccessibilityIdentifier("choose-thunderbird-root")
        let refresh = NSButton(title: "刷新文件夹", target: self, action: #selector(refresh))
        refresh.setAccessibilityIdentifier("refresh-source-folders")
        let sync = NSButton(title: "同步所选", target: self, action: #selector(syncSelected))
        sync.setAccessibilityIdentifier("sync-selected-folders")
        let remove = NSButton(title: "删除已同步", target: self, action: #selector(removeSelected))
        remove.setAccessibilityIdentifier("remove-synced-folders")
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelSync))
        cancel.setAccessibilityIdentifier("cancel-sync"); cancel.isEnabled = false
        rootButton = root; refreshButton = refresh; syncButton = sync; removeButton = remove; cancelButton = cancel
        titlebarControls(window, [root, refresh, remove, cancel, sync])
    }

    @objc
    private func refresh() {
        reload()
    }

    /// `message`: 同步 / 删除结果, 刷新后保留在状态栏.
    func reload(message: String? = nil) {
        guard !syncing else { return }
        refreshTask?.cancel()
        let root = ConfigStore.config.thunderbirdRoot
        status.stringValue = message ?? "正在读取本地账户／文件夹…"
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let discovered = try await engine.call(
                    EngineRequest(operation: "discover", root: root),
                    as: [MailFolder].self
                )
                let library = try await engine.call(EngineRequest(operation: "status"), as: LibraryState.self)
                guard !Task.isCancelled else { return }
                let known = Set(discovered.map(\.id))
                let orphans = library.folders.map(\.folder).filter { !known.contains($0.id) }
                    .sorted { ($0.account, $0.name) < ($1.account, $1.name) }
                let list = discovered + orphans
                folders = list
                synced = Dictionary(library.folders.map { ($0.folder.id, $0) }) { first, _ in first }
                missing = Set(orphans.map(\.id))
                selected.formIntersection(Set(list.map(\.id)))
                restoringSelection = true
                table.reloadData()
                table.selectRowIndexes(IndexSet(list.indices.filter { selected.contains(list[$0].id) }),
                                       byExtendingSelection: false)
                restoringSelection = false
                status.stringValue = message ?? summary()
                source.stringValue = "只读来源：\(root)"
            } catch { status.stringValue = error.localizedDescription }
        }
    }

    private func summary() -> String {
        "发现 \(folders.count - missing.count) 个本地文件夹 · 已同步 \(synced.count) 个 · 已选 \(selected.count) 个"
    }

    @objc
    private func chooseRoot() {
        guard !syncing, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 profiles.ini 的 Thunderbird 目录"
        panel.directoryURL = URL(fileURLWithPath: ConfigStore.config.thunderbirdRoot)
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            guard FileManager.default.fileExists(atPath: url.appendingPathComponent("profiles.ini").path) else {
                status.stringValue = "所选目录没有 profiles.ini"; return
            }
            ConfigStore.updateConfig { $0.thunderbirdRoot = url.path }
            refresh()
        }
    }

    func numberOfRows(in _: NSTableView) -> Int {
        folders.count
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < folders.count, let column = tableColumn else { return nil }
        let folder = folders[row]
        let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField ?? label("")
        cell.identifier = column.identifier
        cell.font = .systemFont(ofSize: 12)
        switch column.identifier.rawValue {
        case "account": cell.stringValue = folder.account
        case "folder": cell.stringValue = folder.name
        default:
            let count = synced[folder.id].map { "\($0.count) 封" } ?? ""
            cell.stringValue = missing.contains(folder.id) ? "\(count) · 来源已不存在" : count
        }
        cell.toolTip = folder.store
        return cell
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !syncing, !restoringSelection else { return }
        selected = Set(table.selectedRowIndexes.compactMap { index in
            index < folders.count ? folders[index].id : nil
        })
        ConfigStore.update { $0.selectedSourceFolders = selected.sorted() }
        status.stringValue = summary()
    }

    @objc
    private func syncSelected() {
        guard !syncing else { return }
        let ids = selected.subtracting(missing).sorted()
        guard !ids.isEmpty else {
            status.stringValue = selected.isEmpty ? "请选择待同步文件夹" : "所选文件夹来源已不存在，只能删除"; return
        }
        setBusy(true)
        cancelButton?.isEnabled = true
        status.stringValue = "正在关闭 Thunderbird…"
        let root = ConfigStore.config.thunderbirdRoot
        syncTask = Task { [weak self] in
            guard let self else { return }
            progressTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self else { return }
                    showEngineProgress()
                }
            }
            do {
                try await closeThunderbird()
                try Task.checkCancellation()
                status.stringValue = "正在建立只读快照并导入…"
                let result = try await engine.call(
                    EngineRequest(operation: "sync", root: root, folders: ids),
                    as: SyncResult.self
                )
                let total = result.folders.reduce(0) { $0 + $1.count }
                let updated = result.folders.reduce(0) { $0 + $1.updated }
                let missing = result.folders.reduce(0) { $0 + $1.unavailable }
                let elapsed = String(format: "%.1f", result.elapsedMs / 1000)
                status.stringValue = "同步完成 · \(total) 封本地邮件 · 新增／更新 \(updated)"
                    + " · \(missing) 封正文未下载 · \(elapsed) s"
            } catch is CancellationError {
                status.stringValue = "同步已取消；已提交邮件保留，下次同步继续"
            } catch { status.stringValue = error.localizedDescription }
            progressTask?.cancel(); progressTask = nil
            setBusy(false)
            reload(message: status.stringValue)
            libraryChanged?()
        }
    }

    /// 同步 / 删除共用: 引擎串行写索引, 期间锁定选择与全部操作按钮.
    func setBusy(_ busy: Bool) {
        syncing = busy
        table.isEnabled = !busy
        for button in [syncButton, rootButton, refreshButton, removeButton] { button?.isEnabled = !busy }
        cancelButton?.isEnabled = false
        showProgress(busy)
    }

    private func showEngineProgress() {
        guard let value = engine.progress(), value.total > 0 else { return }
        if progress.isIndeterminate {
            progress.stopAnimation(nil); progress.isIndeterminate = false
        }
        progress.doubleValue = Double(value.current) / Double(value.total)
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(value.bytes), countStyle: .file)
        status.stringValue = "处理 \(value.current) / \(value.total)"
            + " · 新增／更新 \(value.imported) · 已读取 \(bytes)"
    }

    /// 关闭 Thunderbird / 快照阶段引擎尚无总数: 先显示不确定进度, 首个总数到达后切换.
    private func showProgress(_ visible: Bool) {
        progress.isIndeterminate = visible; progress.isHidden = !visible
        if visible {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    @objc
    private func cancelSync() {
        syncTask?.cancel(); engine.cancel()
        cancelButton?.isEnabled = false
        status.stringValue = "正在取消，已提交邮件会保留…"
    }
}

private extension SettingsViewController {
    func closeThunderbird() async throws {
        let processes = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == "org.mozilla.thunderbird" || $0.executableURL?.path
                .contains("Thunderbird.app/Contents/MacOS/") == true
        }
        // 仅正常退出; 强制结束可能中断 Thunderbird 写入 .msf / mbox, 损坏同步源.
        for app in processes { _ = app.terminate() }
        for _ in 0..<300 {
            try Task.checkCancellation()
            if processes.allSatisfy(\.isTerminated) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw EngineError(message: "Thunderbird 30 秒内未退出（可能有未保存的草稿）；请手动退出后重试")
    }
}
