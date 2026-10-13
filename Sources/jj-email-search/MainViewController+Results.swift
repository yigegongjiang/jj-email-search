import AppKit

extension MainViewController {
    func installTitlebar(in window: NSWindow) {
        let settings = NSButton(title: "同步设置", target: self, action: #selector(showSettings))
        settings.setAccessibilityIdentifier("open-sync-settings")
        let save = NSButton(title: "导出邮件", target: self, action: #selector(exportMessage))
        save.setAccessibilityIdentifier("export-mail")
        let attachment = NSButton(title: "保存附件", target: self, action: #selector(exportAttachment))
        attachment.setAccessibilityIdentifier("save-attachment")
        exportButton = save; attachmentButton = attachment
        titlebarControls(window, [save, attachment, settings])
        updateActions()
    }

    @objc
    func showSettings() {
        openSettings?()
    }

    @objc
    func previewChanged() {
        updatePreviewBody()
    }

    @objc
    func attachmentChanged() {
        updateActions()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(search)
        search.selectText(nil)
    }

    /// 搜索框内 ↓ / ↩ 进入结果列表, 键盘即可浏览.
    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.moveDown(_:)) || selector == #selector(NSResponder.insertNewline(_:)),
              !items.isEmpty else { return false }
        view.window?.makeFirstResponder(table)
        if table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        table.scrollRowToVisible(max(table.selectedRow, 0))
        return true
    }

    func numberOfRows(in _: NSTableView) -> Int {
        items.count
    }

    func tableView(_: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let column = tableColumn else { return nil }
        let item = items[row]
        let field = column.identifier.rawValue
        let cell = table.makeView(withIdentifier: column.identifier, owner: nil) as? NSTextField ?? label("")
        cell.identifier = column.identifier
        cell.font = .systemFont(ofSize: 12, weight: item.flags & 1 == 0 ? .semibold : .regular)
        switch field {
        case "subject": cell.stringValue = (item.complete == 0 ? "⚠ " : "") + item.subject
        case "sender": cell.stringValue = item.sender
        case "date": cell.stringValue = dateFormatter.string(from: Date(timeIntervalSince1970: item.date))
        case "attachments": cell.stringValue = item.attachments == 0 ? "" : String(item.attachments)
        default: cell.stringValue = ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)
        }
        cell.toolTip = cell.stringValue
        cell.setAccessibilityIdentifier("mail-\(item.id)-\(field)")
        return cell
    }

    func tableView(_: NSTableView, sortDescriptorsDidChange _: [NSSortDescriptor]) {
        items = Self.sorted(items, key: sortOrder.key, ascending: sortOrder.ascending)
        reloadKeepingSelection()
    }

    func tableViewSelectionDidChange(_: Notification) {
        guard !reloadingResults else { return }
        let item = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil
        // 同一邮件重新定位行号时保留已加载预览.
        guard item?.id != previewID || item == nil else { return }
        previewTask?.cancel(); previewSequence += 1
        highlightTask?.cancel(); highlightSequence += 1
        previewID = item?.id; preview = nil
        attachments.removeAllItems(); attachments.addItem(withTitle: "无附件"); attachments.isEnabled = false
        headerScroll?.isHidden = item == nil
        updateActions()
        guard let item else {
            header.string = ""; body.string = placeholder
            updatePreviewHighlights()
            return
        }
        let version = previewSequence
        header.textStorage?.setAttributedString(headerText(item))
        updatePreviewHighlights()
        body.string = engine.isSyncing ? "同步进行中，预览将在同步结束后读取…" : "正在读取邮件…"
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await engine.call(
                    EngineRequest(operation: "preview", id: item.id),
                    as: MailPreview.self
                )
                guard !Task.isCancelled, previewSequence == version else { return }
                preview = value
                attachments.removeAllItems()
                for (position, attachment) in value.attachments.enumerated() {
                    let attachmentSize = ByteCountFormatter.string(
                        fromByteCount: Int64(attachment.size), countStyle: .file
                    )
                    let availability = attachment.available ? "" : "（不可用）"
                    // 序号 / 总数: 弹出框收起时也能看出共几个附件.
                    attachments.addItem(withTitle: "附件 \(position + 1)/\(value.attachments.count) · "
                        + "\(attachment.name) · \(attachmentSize)\(availability)")
                    attachments.lastItem?.representedObject = attachment.index
                }
                attachments.isEnabled = !value.attachments.isEmpty
                if value.attachments.isEmpty {
                    attachments.addItem(withTitle: "无附件")
                }
                updatePreviewBody()
                updateActions()
            } catch {
                if previewSequence == version {
                    body.string = error.localizedDescription
                }
            }
        }
    }

    /// 无选中邮件时的预览区提示; 空库时引导同步.
    var placeholder: String {
        libraryCount <= 0
            ? "还没有可检索的邮件。\n\n1. 点击右上角「同步设置」\n2. 选中 Thunderbird 文件夹（⌘ 点击可多选）\n3. 点击「同步所选」"
            : "选择邮件以预览正文。所有内容均来自本地，不加载远程资源。"
    }

    /// 导出 / 保存附件仅在可执行时启用; 与 `export` / `exportAttachment` 守卫一致.
    func updateActions() {
        let hasMail = table.selectedRow >= 0 && table.selectedRow < items.count
        exportButton?.isEnabled = hasMail
        let index = attachments.selectedItem?.representedObject as? Int
        attachmentButton?.isEnabled = hasMail && preview?.attachments
            .first(where: { $0.index == index })?.available == true
    }

    private func headerText(_ item: MailItem) -> NSAttributedString {
        let date = dateFormatter.string(from: Date(timeIntervalSince1970: item.date))
        let text = NSMutableAttributedString(string: item.subject.isEmpty ? "（无主题）" : item.subject, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
        ])
        let detail: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ]
        for line in ["发件人：\(item.sender)", "收件人：\(item.recipients)",
                     "\(date) · \(item.account) · \(item.folderName)"] {
            text.append(NSAttributedString(string: "\n" + line, attributes: detail))
        }
        return text
    }

    func updatePreviewBody() {
        guard let preview else { return }
        // 整封为引用 / 无独立正文时回退完整正文, 避免空白预览.
        let own = preview.ownBody.trimmingCharacters(in: .whitespacesAndNewlines)
        body.string = previewMode.indexOfSelectedItem == 0 && !own.isEmpty ? preview.ownBody : preview.body
        body.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updatePreviewHighlights(scrollToMatch: true)
    }

    @objc
    func exportMessage() {
        export(attachment: nil)
    }

    @objc
    func exportAttachment() {
        guard let index = attachments.selectedItem?.representedObject as? Int,
              preview?.attachments.first(where: { $0.index == index })?.available == true else {
            status.stringValue = "请选择一个可用附件"; return
        }
        export(attachment: index)
    }

    func export(attachment: Int?) {
        guard table.selectedRow >= 0, table.selectedRow < items.count else { status.stringValue = "请先选择邮件"; return }
        let item = items[table.selectedRow]
        let panel = NSSavePanel()
        let name = attachment.flatMap { index in preview?.attachments.first(
            where: { $0.index == index }
        )?.name } ?? "mail.eml"
        panel.nameFieldStringValue = URL(fileURLWithPath: name).lastPathComponent
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    _ = try await engine.call(
                        EngineRequest(operation: "export", id: item.id, path: url.path, attachment: attachment),
                        as: EmptyResult.self
                    )
                    status.stringValue = "已保存：\(url.lastPathComponent)"
                } catch { status.stringValue = error.localizedDescription }
            }
        }
    }

    /// reloadData 按行号保留选中; 按邮件 ID 重新定位, 不在结果中则清空预览.
    func reloadKeepingSelection() {
        let selected = previewID
        reloadingResults = true
        defer {
            reloadingResults = false
            tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        }
        table.reloadData()
        if let selected, let row = items.firstIndex(where: { $0.id == selected }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }

    /// 当前列头排序; 默认日期倒序 = 引擎返回顺序.
    var sortOrder: (key: String, ascending: Bool) {
        let descriptor = table.sortDescriptors.first
        return (descriptor?.key ?? "date", descriptor?.ascending ?? false)
    }

    /// 全量结果可达数万封: 检索路径在后台线程排序, 不阻塞主线程.
    nonisolated static func sorted(_ items: [MailItem], key: String, ascending: Bool) -> [MailItem] {
        if key == "date", !ascending {
            return items.sorted { ($0.date, $1.id) > ($1.date, $0.id) }
        }
        return items.sorted { lhs, rhs in
            let left: (String, Double), right: (String, Double)
            switch key {
            case "subject": (left, right) = ((lhs.subject, 0), (rhs.subject, 0))
            case "sender": (left, right) = ((lhs.sender, 0), (rhs.sender, 0))
            case "attachments": (left, right) = (("", Double(lhs.attachments)), ("", Double(rhs.attachments)))
            case "size": (left, right) = (("", Double(lhs.size)), ("", Double(rhs.size)))
            default: (left, right) = (("", lhs.date), ("", rhs.date))
            }
            if left == right {
                return lhs.date > rhs.date
            }
            return ascending ? left < right : left > right
        }
    }
}
