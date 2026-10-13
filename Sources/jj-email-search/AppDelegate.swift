import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var engine: MailEngine?
    private var mainController: MainViewController?
    private var frameObservers: [NSObjectProtocol] = []
    private var pendingFrameSave: Task<Void, Never>?

    func applicationDidFinishLaunching(_: Notification) {
        ConfigStore.load()
        // 单窗口 App 不使用标签页; 关闭后菜单不再注入标签页相关项.
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.mainMenu = makeMainMenu()

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.subtitle = ConfigStore.warnings
        window.contentMinSize = NSSize(width: 920, height: 500)
        do {
            let engine = try MailEngine(directory: ConfigStore.directory.appendingPathComponent(
                "mail-index",
                isDirectory: true
            ))
            self.engine = engine
            let controller = MainViewController(engine: engine)
            controller.openSettings = { [weak self] in self?.showSettings() }
            window.contentViewController = controller
            controller.installTitlebar(in: window)
            mainController = controller
        } catch {
            window.contentView = NSTextField(labelWithString: error.localizedDescription)
        }
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

    @objc
    private func showSettings() {
        guard let engine else { return }
        if settingsWindow == nil {
            let controller = SettingsViewController(engine: engine)
            controller.syncFinished = { [weak self] in
                guard let self else { return }
                Task { await mainController?.refreshLibrary() }
            }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 850, height: 620),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Thunderbird 同步设置"
            window.contentMinSize = NSSize(width: 650, height: 420)
            window.contentViewController = controller
            window.isReleasedWhenClosed = false
            controller.installTitlebar(in: window)
            window.center()
            settingsWindow = window
        }
        if ProcessInfo.processInfo.environment["APP_BACKGROUND"] == "1", !NSApp.isActive {
            settingsWindow?.orderBack(nil)
        } else {
            settingsWindow?.makeKeyAndOrderFront(nil)
        }
    }

    @objc
    private func focusSearch() {
        window?.makeKeyAndOrderFront(nil)
        mainController?.focusSearch()
    }

    func applicationWillTerminate(_: Notification) {
        engine?.cancel()
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

    /// 无 nib 时 AppKit 不生成菜单栏; 按 macOS 标准菜单结构手动构建.
    /// 服务列表 / 窗口列表 / 帮助搜索框由系统按 servicesMenu / windowsMenu / helpMenu 注入.
    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        for submenu in [
            makeAppMenu(),
            makeFileMenu(),
            makeEditMenu(),
            makeViewMenu(),
            makeWindowMenu(),
            makeHelpMenu()
        ] {
            let item = NSMenuItem()
            item.submenu = submenu
            mainMenu.addItem(item)
        }
        return mainMenu
    }

    private func makeAppMenu() -> NSMenu {
        let menu = NSMenu(title: appName)
        let about = #selector(NSApplication.orderFrontStandardAboutPanel(_:))
        menu.addItem(withTitle: "关于 \(appName)", action: about, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        let services = NSMenu(title: "服务")
        menu.addItem(withTitle: "服务", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "隐藏 \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = #selector(NSApplication.hideOtherApplications(_:))
        menu.addItem(withTitle: "隐藏其他", action: hideOthers, keyEquivalent: "h").keyEquivalentModifierMask = [
            .command,
            .option
        ]
        let showAll = #selector(NSApplication.unhideAllApplications(_:))
        menu.addItem(withTitle: "全部显示", action: showAll, keyEquivalent: "")
        menu.addItem(.separator())
        let quit = #selector(NSApplication.terminate(_:))
        menu.addItem(withTitle: "退出 \(appName)", action: quit, keyEquivalent: "q")
        return menu
    }

    private func makeFileMenu() -> NSMenu {
        let menu = NSMenu(title: "文件")
        menu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        return menu
    }

    /// 文本框 / 预览的 ⌘C / ⌘V / ⌘A 依赖编辑菜单项分发 (nil target -> 响应链).
    private func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "编辑")
        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(withTitle: "搜索邮件", action: #selector(focusSearch), keyEquivalent: "f").target = self
        return menu
    }

    private func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: "显示")
        let fullScreen = #selector(NSWindow.toggleFullScreen(_:))
        menu.addItem(withTitle: "进入全屏幕", action: fullScreen, keyEquivalent: "f").keyEquivalentModifierMask = [
            .command,
            .control
        ]
        return menu
    }

    private func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "窗口")
        let minimize = #selector(NSWindow.performMiniaturize(_:))
        menu.addItem(withTitle: "最小化", action: minimize, keyEquivalent: "m")
        menu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        let front = #selector(NSApplication.arrangeInFront(_:))
        menu.addItem(withTitle: "前置全部窗口", action: front, keyEquivalent: "")
        NSApp.windowsMenu = menu
        return menu
    }

    private func makeHelpMenu() -> NSMenu {
        let menu = NSMenu(title: "帮助")
        menu.addItem(withTitle: "\(appName) 帮助", action: #selector(openHelp), keyEquivalent: "?").target = self
        NSApp.helpMenu = menu
        return menu
    }

    /// 无 Help Book; 帮助指向仓库 README.
    @objc
    private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://github.com/yigegongjiang/jj-email-search#readme")!)
    }
}
