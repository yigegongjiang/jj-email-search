import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var frameObservers: [NSObjectProtocol] = []
    private var pendingFrameSave: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        ConfigStore.load()
        NSApp.mainMenu = makeMainMenu()

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.subtitle = ConfigStore.warnings
        window.contentMinSize = NSSize(width: 480, height: 320)
        window.contentViewController = MainViewController()
        window.isReleasedWhenClosed = false
        restoreFrame(window)
        self.window = window
        // 自动化启动置于其他窗口之后, 不激活 App.
        if ProcessInfo.processInfo.environment["APP_BACKGROUND"] != "1" {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        } else {
            window.orderBack(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }

    /// 窗口位置 / 尺寸存 state.json; 已不在任何屏幕内则居中.
    private func restoreFrame(_ window: NSWindow) {
        if let saved = ConfigStore.state.window {
            let frame = NSRect(x: saved.minX, y: saved.minY, width: saved.width, height: saved.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) {
                window.setFrame(frame, display: false)
            } else {
                window.center()
            }
        } else {
            window.center()
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleFrameSave() }
            })
        }
    }

    /// 拖动 / 缩放过程中连续触发, 停止 0.5 秒后再写入.
    private func scheduleFrameSave() {
        pendingFrameSave?.cancel()
        pendingFrameSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let frame = self?.window?.frame else { return }
            ConfigStore.update {
                $0.window = WindowFrame(minX: frame.minX, minY: frame.minY, width: frame.width, height: frame.height)
            }
        }
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "jj-email-search"
    }

    /// 无 nib 时系统不生成菜单栏; 最小菜单保证 ⌘Q / ⌘W / ⌘M 可用.
    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        let quit = #selector(NSApplication.terminate(_:))
        appMenu.addItem(withTitle: "Quit \(appName)", action: quit, keyEquivalent: "q")

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let minimize = #selector(NSWindow.performMiniaturize(_:))
        windowMenu.addItem(withTitle: "Minimize", action: minimize, keyEquivalent: "m")
        NSApp.windowsMenu = windowMenu

        let mainMenu = NSMenu()
        for submenu in [appMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }
}
