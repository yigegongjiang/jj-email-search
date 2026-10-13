import AppKit

extension MainViewController {
    func updateSearchHighlights(_ result: SearchResult) {
        highlightTerms = result.highlightTerms
        updatePreviewHighlights(scrollToMatch: true)
    }

    /// Native token matching runs on the engine queue; stale replies never modify the preview.
    func updatePreviewHighlights(scrollToMatch: Bool = false) {
        highlightTask?.cancel(); highlightSequence += 1
        for text in [header, body] {
            text.textStorage?.removeAttribute(
                .backgroundColor,
                range: NSRange(location: 0, length: text.string.utf16.count)
            )
            text.setAccessibilityHelp(nil)
        }
        guard let selected = previewID, let item = items.first(where: { $0.id == selected }),
              !highlightTerms.isEmpty else { return }
        let subject = item.subject.isEmpty ? "（无主题）" : item.subject
        let senderOffset = (subject + "\n发件人：").utf16.count
        let recipientsOffset = senderOffset + (item.sender + "\n收件人：").utf16.count
        let texts = [
            HighlightTerm(field: "subject", text: item.subject),
            HighlightTerm(field: "sender", text: item.sender),
            HighlightTerm(field: "recipients", text: item.recipients),
            HighlightTerm(field: "body", text: preview == nil ? "" : body.string)
        ]
        let offsets = [0, senderOffset, recipientsOffset, 0]
        let version = highlightSequence
        highlightTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.call(
                    EngineRequest(operation: "highlight", terms: highlightTerms, texts: texts),
                    as: HighlightResult.self
                )
                guard !Task.isCancelled, highlightSequence == version, previewID == selected else { return }
                applyPreviewHighlights(result, offsets: offsets)
                if scrollToMatch, let first = result.ranges.last?.first {
                    body.scrollRangeToVisible(NSRange(location: first.location, length: first.length))
                }
            } catch {
                guard !Task.isCancelled, highlightSequence == version else { return }
                body.setAccessibilityHelp("检索高亮失败：\(error.localizedDescription)")
            }
        }
    }

    private func applyPreviewHighlights(_ result: HighlightResult, offsets: [Int]) {
        var counts = [0, 0]
        for (index, ranges) in result.ranges.enumerated() where index < offsets.count {
            let target = index == 3 ? body : header
            guard let storage = target.textStorage else { continue }
            storage.beginEditing()
            for range in ranges {
                let span = NSRange(location: offsets[index] + range.location, length: range.length)
                guard NSMaxRange(span) <= storage.length else { continue }
                storage.addAttribute(.backgroundColor,
                                     value: NSColor.systemYellow.withAlphaComponent(0.45), range: span)
                counts[index == 3 ? 1 : 0] += 1
            }
            storage.endEditing()
        }
        header.setAccessibilityHelp("检索高亮：\(counts[0]) 处")
        body.setAccessibilityHelp("检索高亮：\(counts[1]) 处")
    }
}
