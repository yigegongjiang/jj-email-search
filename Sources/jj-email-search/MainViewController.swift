import AppKit

@MainActor
final class MainViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let engine: MailEngine
    var openSettings: (() -> Void)?
    let search = AccessibleSearchField()
    private let folders = AccessiblePopUp()
    private let fields = AccessiblePopUp()
    let table = AccessibleTable()
    let status = label("正在打开邮件库…", identifier: "search-status")
    let header = NSTextView()
    let body = NSTextView()
    let previewMode = AccessiblePopUp()
    let attachments = AccessiblePopUp()
    var items: [MailItem] = []
    var preview: MailPreview?
    var previewID: String?
    private var libraryCount = 0
    private var queryTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    private var sequence = 0
    var previewSequence = 0
    private var loadedLibrary = false
    let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    init(engine: MailEngine) {
        self.engine = engine; super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 850))
        configureSearchControls()
        let bar = NSStackView(views: [folders, fields, search])
        bar.spacing = 6
        folders.widthAnchor.constraint(equalToConstant: 310).isActive = true
        fields.widthAnchor.constraint(equalToConstant: 100).isActive = true
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        let split = NSSplitView()
        split.isVertical = true; split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        configureResultsTable()
        let results = NSScrollView()
        results.documentView = table
        results.hasVerticalScroller = true; results.hasHorizontalScroller = true
        results.autohidesScrollers = true
        let pane = makePreviewPane()
        split.addArrangedSubview(results); split.addArrangedSubview(pane)
        results.widthAnchor.constraint(greaterThanOrEqualToConstant: 460).isActive = true
        pane.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        view.addSubview(bar); view.addSubview(split); view.addSubview(status)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            bar.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            bar.heightAnchor.constraint(equalToConstant: 26),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            split.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            status.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            status.heightAnchor.constraint(equalToConstant: 16)
        ])
        split.setPosition(900, ofDividerAt: 0)
        Task { await refreshLibrary() }
    }

    private func configureSearchControls() {
        search.placeholderString = "搜索主题、发件人或正文；支持 AND / OR / NOT 和 \"短语\""
        search.setAccessibilityIdentifier("mail-search")
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.changed = { [weak self] in self?.scheduleSearch() }
        search.stringValue = ConfigStore.state.searchQuery
        fields.addItems(withTitles: ["全部字段", "主题", "发件人", "收件人", "正文"])
        for (index, name) in ["all", "subject", "sender", "recipients", "body"].enumerated() {
            fields.item(at: index)?.representedObject = name
        }
        fields.target = self; fields.action = #selector(scopeChanged)
        fields.setAccessibilityIdentifier("search-field")
        folders.addItem(withTitle: "全部已同步文件夹")
        folders.item(at: 0)?.representedObject = ""
        folders.target = self; folders.action = #selector(scopeChanged)
        folders.setAccessibilityIdentifier("search-folder")
    }

    private func configureResultsTable() {
        table.dataSource = self; table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.setAccessibilityIdentifier("mail-results")
        for (identifier, title, width) in [("subject", "主题", 380.0), ("sender", "发件人", 210.0),
                                           ("date", "日期", 135.0), ("attachments", "附件", 45.0), ("size", "大小", 65.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title; column.width = width; column.minWidth = 40
            // 文本列默认升序, 数值 / 日期列默认降序.
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: identifier == "subject"
                || identifier == "sender")
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "date", ascending: false)]
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    }

    private func makePreviewPane() -> NSView {
        previewMode.addItems(withTitles: ["当前邮件正文", "完整邮件正文"])
        previewMode.target = self; previewMode.action = #selector(previewChanged)
        previewMode.setAccessibilityIdentifier("preview-mode")
        attachments.addItem(withTitle: "无附件")
        attachments.setAccessibilityIdentifier("mail-attachments")
        attachments.isEnabled = false
        let controls = NSStackView(views: [previewMode, attachments])
        controls.spacing = 6
        for text in [header, body] {
            text.isEditable = false; text.isSelectable = true
            text.isRichText = false; text.drawsBackground = true
            text.backgroundColor = .textBackgroundColor
            text.textContainerInset = NSSize(width: 8, height: 6)
            text.autoresizingMask = [.width]
            text.textContainer?.widthTracksTextView = true
            text.isHorizontallyResizable = false
        }
        header.font = .systemFont(ofSize: 12)
        header.setAccessibilityIdentifier("mail-header")
        body
            .font = .systemFont(ofSize: (10...18).contains(ConfigStore.config.fontSize) ? ConfigStore.config
                .fontSize : 12)
        body.setAccessibilityIdentifier("mail-body")
        body.string = "选择邮件以预览正文。所有内容均来自本地，不加载远程资源。"
        let headerScroll = NSScrollView()
        headerScroll.documentView = header; headerScroll.hasVerticalScroller = true
        headerScroll.heightAnchor.constraint(equalToConstant: 80).isActive = true
        let bodyScroll = NSScrollView()
        bodyScroll.documentView = body; bodyScroll.hasVerticalScroller = true
        let pane = NSStackView(views: [controls, headerScroll, bodyScroll])
        pane.orientation = .vertical; pane.alignment = .leading; pane.spacing = 2
        for child in [controls, headerScroll, bodyScroll] {
            child.widthAnchor.constraint(equalTo: pane.widthAnchor).isActive = true
        }
        return pane
    }

    func installTitlebar(in window: NSWindow) {
        let settings = NSButton(title: "同步设置", target: self, action: #selector(showSettings))
        settings.setAccessibilityIdentifier("open-sync-settings")
        let save = NSButton(title: "导出邮件", target: self, action: #selector(exportMessage))
        save.setAccessibilityIdentifier("export-mail")
        let attachment = NSButton(title: "保存附件", target: self, action: #selector(exportAttachment))
        attachment.setAccessibilityIdentifier("save-attachment")
        titlebarControls(window, [save, attachment, settings])
    }

    @objc
    private func showSettings() {
        openSettings?()
    }

    @objc
    private func scopeChanged() {
        scheduleSearch(immediate: true)
    }

    @objc
    private func previewChanged() {
        updatePreviewBody()
    }

    func refreshLibrary() async {
        do {
            let state = try await engine.call(EngineRequest(operation: "status"), as: LibraryState.self)
            let selected = loadedLibrary
                ? (folders.selectedItem?.representedObject as? String ?? "")
                : ConfigStore.state.searchFolder
            loadedLibrary = true
            libraryCount = state.count
            folders.removeAllItems()
            folders.addItem(withTitle: "全部已同步文件夹（\(state.count)）")
            folders.item(at: 0)?.representedObject = ""
            for folder in state.folders.sorted(by: { ($0.folder.account, $0.folder.name) < (
                $1.folder.account,
                $1.folder.name
            ) }) {
                // 文件夹名 + 数量在前, 弹出框截断时仍可见.
                folders.addItem(withTitle: "\(folder.folder.name)（\(folder.count)） · \(folder.folder.account)")
                folders.lastItem?.representedObject = folder.folder.id
                folders.lastItem?.toolTip = folders.lastItem?.title
            }
            let restored = folders.itemArray.firstIndex { ($0.representedObject as? String) == selected }
            folders.selectItem(at: restored ?? (state.folders.count == 1 ? 1 : 0))
            scheduleSearch(immediate: true)
        } catch { status.stringValue = error.localizedDescription }
    }

    func controlTextDidChange(_: Notification) {
        scheduleSearch()
    }

    private func scheduleSearch(immediate: Bool = false) {
        queryTask?.cancel()
        sequence += 1
        let version = sequence
        let query = search.stringValue
        let folder = folders.selectedItem?.representedObject as? String ?? ""
        let field = fields.selectedItem?.representedObject as? String ?? "all"
        queryTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(160))
            }
            guard !Task.isCancelled, let self else { return }
            ConfigStore.update { $0.searchQuery = query; $0.searchFolder = folder }
            status.stringValue = engine.isSyncing ? "同步进行中，检索将在同步结束后执行…" : "正在检索…"
            let start = ContinuousClock.now
            do {
                let result = try await engine.call(
                    EngineRequest(
                        operation: "search",
                        folders: folder.isEmpty ? [] : [folder],
                        query: query,
                        field: field
                    ),
                    as: SearchResult.self
                )
                let order = sortOrder
                let sorted = order.key == "date" && !order.ascending ? result.items : await Task.detached {
                    MainViewController.sorted(result.items, key: order.key, ascending: order.ascending)
                }.value
                guard !Task.isCancelled, sequence == version else { return }
                items = order == sortOrder ? sorted : Self.sorted(sorted, key: sortOrder.key,
                                                                  ascending: sortOrder.ascending)
                reloadKeepingSelection()
                let elapsed = start.duration(to: .now)
                let elapsedMilliseconds = Double(elapsed.components.seconds) * 1000 +
                    Double(elapsed.components.attoseconds) / 1e15
                let totalTime = String(format: "%.1f", elapsedMilliseconds)
                let engineTime = String(format: "%.1f", result.elapsedMs)
                status.stringValue = libraryCount <= 0
                    ? "尚未同步邮件；打开右上角“同步设置”选择源文件夹。"
                    : "\(result.count) 封匹配 · 全量返回 \(totalTime) ms · 引擎 \(engineTime) ms"
                    + (result.relaxed ? " · 查询语法不完整，已按关键词检索" : "")
                status.setAccessibilityValue(status.stringValue)
            } catch {
                guard sequence == version else { return }
                status.stringValue = error.localizedDescription
            }
        }
    }
}
