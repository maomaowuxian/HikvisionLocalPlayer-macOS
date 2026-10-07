import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let engine = Go2RtcController()
    private var window: NSWindow!
    private var mainViewController: MainViewController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()

        mainViewController = MainViewController(engine: engine)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = PlayerTheme.canvas
        window.title = "海康威视播放器"
        window.minSize = NSSize(width: 980, height: 680)
        window.contentViewController = mainViewController
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !flag { window.makeKeyAndOrderFront(nil) }
        updatePlaybackVisibility()
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainViewController?.prepareForTermination()
        engine.shutdownSynchronously()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        mainViewController?.setFullscreenLayout(true)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        mainViewController?.setFullscreenLayout(true)
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        mainViewController?.setFullscreenLayout(false)
    }

    func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        mainViewController?.setFullscreenLayout(false)
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        mainViewController?.setFullscreenLayout(true)
    }

    // Occlusion notifications also fire during animations and when another
    // window covers us. Only explicit minimize/hide suspends live playback.
    func windowDidMiniaturize(_ notification: Notification) {
        updatePlaybackVisibility()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        updatePlaybackVisibility()
    }

    func applicationDidHide(_ notification: Notification) {
        updatePlaybackVisibility()
    }

    func applicationDidUnhide(_ notification: Notification) {
        updatePlaybackVisibility()
    }

    @MainActor
    private func updatePlaybackVisibility() {
        guard let window else { return }
        if window.isMiniaturized || NSApp.isHidden {
            mainViewController?.pausePlayback()
        } else {
            mainViewController?.resumePlayback()
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        let appName = "海康威视播放器"
        appMenu.addItem(
            withTitle: "关于\(appName)",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏\(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出\(appName)",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(
            withTitle: "撤销",
            action: Selector(("undo:")),
            keyEquivalent: "z"
        )
        editMenu.addItem(
            withTitle: "重做",
            action: Selector(("redo:")),
            keyEquivalent: "Z"
        )
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: "剪切",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: "复制",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: "粘贴",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: "全选",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu

        let windowItem = NSMenuItem()
        mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(
            withTitle: "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        windowMenu.addItem(
            withTitle: "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: ""
        )
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
