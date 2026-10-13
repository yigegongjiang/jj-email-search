import AppKit
import ImageIO

private final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

/// 预览区图片附件: 正文下方分栏, 无图片时隐藏.
@MainActor
struct ImageArea {
    let split = NSSplitView()
    let scroll = NSScrollView()
    let stack = NSStackView()
    var task: Task<Void, Never>?
    /// 图片区占预览区高度比例; 隐藏前记录, 保留用户拖动结果.
    var fraction: CGFloat = 0.6
}

extension MainViewController {
    /// 单封邮件最多渲染的图片数; 缩略图按预览区像素宽度解码, 内存有上限.
    private static let maxImages = 30

    func configureImageArea(below bodyScroll: NSScrollView) {
        images.split.isVertical = false; images.split.dividerStyle = .thin
        images.stack.orientation = .vertical; images.stack.alignment = .leading; images.stack.spacing = 4
        images.stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        images.stack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(images.stack)
        images.scroll.documentView = document
        images.scroll.hasVerticalScroller = true; images.scroll.autohidesScrollers = true
        images.scroll.setAccessibilityIdentifier("attachment-images")
        let clip = images.scroll.contentView
        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            images.stack.topAnchor.constraint(equalTo: document.topAnchor),
            images.stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            images.stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            images.stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        images.split.addArrangedSubview(bodyScroll); images.split.addArrangedSubview(images.scroll)
        // 默认 holding 优先级 (250) 会把分栏压到最小; 调低后由正文吸收预览区剩余高度, 图片区保持拖动后的高度.
        images.split.setHoldingPriority(NSLayoutConstraint.Priority(200), forSubviewAt: 0)
        images.split.setHoldingPriority(NSLayoutConstraint.Priority(240), forSubviewAt: 1)
        // 无图片时隐藏, 正文占满预览区.
        images.scroll.isHidden = true
    }

    func clearImages() {
        images.task?.cancel(); images.task = nil
        if !images.scroll.isHidden, images.split.bounds.height > 0 {
            images.fraction = min(0.9, max(0.1, images.scroll.frame.height / images.split.bounds.height))
        }
        for view in images.stack.arrangedSubviews {
            images.stack.removeArrangedSubview(view); view.removeFromSuperview()
        }
        images.scroll.isHidden = true
    }

    /// 逐张读取: 引擎串行队列不被整封图片长时间占用; 切换邮件即取消未执行的请求.
    func loadImages(_ preview: MailPreview, id: String, version: Int) {
        let total = preview.attachments.count
        let candidates = preview.attachments.enumerated().filter(\.element.image)
        guard !candidates.isEmpty else { return }
        images.scroll.isHidden = false
        images.split.layoutSubtreeIfNeeded()
        images.split.setPosition(images.split.bounds.height * (1 - images.fraction), ofDividerAt: 0)
        images.scroll.documentView?.scroll(.zero)
        let scale = view.window?.backingScaleFactor ?? 2
        let widthPixels = max(800, images.scroll.bounds.width * scale)
        images.task = Task { [weak self] in
            for (position, attachment) in candidates.prefix(Self.maxImages) {
                guard let self, !Task.isCancelled, previewSequence == version else { return }
                let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
                let title = "附件 \(position + 1)/\(total) · \(attachment.name) · \(size)"
                guard attachment.available else {
                    addImageCaption("⚠ \(title)（不可用）", index: attachment.index); continue
                }
                do {
                    let result = try await engine.call(
                        EngineRequest(operation: "attachment", id: id, attachment: attachment.index),
                        as: AttachmentData.self
                    )
                    let image = await Task.detached { Self.thumbnail(result.data, widthPixels: widthPixels) }.value
                    guard !Task.isCancelled, previewSequence == version else { return }
                    addImageCaption(image == nil ? "\(title) · 无法预览" : title, index: attachment.index)
                    if let image {
                        addImage(image, name: attachment.name, index: attachment.index, scale: scale)
                    }
                } catch {
                    guard !Task.isCancelled, previewSequence == version else { return }
                    addImageCaption("⚠ \(title) · \(error.localizedDescription)", index: attachment.index)
                }
            }
            guard let self, previewSequence == version, candidates.count > Self.maxImages else { return }
            addImageCaption("其余 \(candidates.count - Self.maxImages) 张图片未预览，可通过「保存附件」导出", index: nil)
        }
    }

    private func addImageCaption(_ text: String, index: Int?) {
        let caption = label(text, identifier: index.map { "attachment-caption-\($0)" })
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.toolTip = text
        caption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        images.stack.addArrangedSubview(caption)
        caption.widthAnchor.constraint(lessThanOrEqualTo: images.stack.widthAnchor, constant: -12).isActive = true
    }

    private func addImage(_ image: CGImage, name: String, index: Int, scale: CGFloat) {
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let imageView = NSImageView(image: NSImage(cgImage: image, size: size))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityIdentifier("attachment-image-\(index)")
        imageView.setAccessibilityLabel(name)
        imageView.toolTip = name
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
            imageView.setContentHuggingPriority(.defaultLow, for: orientation)
        }
        images.stack.addArrangedSubview(imageView)
        // 原尺寸优先, 超出预览区宽度时等比缩小.
        let natural = imageView.widthAnchor.constraint(equalToConstant: size.width)
        natural.priority = .defaultHigh
        NSLayoutConstraint.activate([
            natural,
            imageView.widthAnchor.constraint(lessThanOrEqualTo: images.stack.widthAnchor, constant: -12),
            imageView.widthAnchor.constraint(equalTo: imageView.heightAnchor, multiplier: size.width / size.height)
        ])
    }

    /// 后台按预览区像素宽度解码 (长边 ≤ 4096); 非图片 / 不支持格式返回 nil.
    nonisolated static func thumbnail(_ data: Data, widthPixels: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              var height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0 else { return nil }
        // EXIF 方向 5...8 = 旋转 90°, 显示宽高互换.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 {
            swap(&width, &height)
        }
        // MaxPixelSize 限制长边: 按显示宽度换算, 竖图也铺满预览区宽度.
        let longSide = min(4096, widthPixels * max(width, height) / width)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longSide
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
