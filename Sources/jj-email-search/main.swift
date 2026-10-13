import AppKit

// 纯 AppKit 入口: 无 nib / storyboard, delegate 需手动挂载; NSApplication.delegate 为 weak, 顶层常量持有强引用.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
