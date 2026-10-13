import AppKit

final class MainViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(labelWithString: "Hello World")
        let size = ConfigStore.config.fontSize
        label.font = .systemFont(ofSize: (8...64).contains(size) ? size : AppConfig().fontSize)
        label.translatesAutoresizingMaskIntoConstraints = false

        // contentViewController 会按此 frame 设定窗口初始尺寸.
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        view.addSubview(label)
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor).isActive = true
        self.view = view
    }
}
