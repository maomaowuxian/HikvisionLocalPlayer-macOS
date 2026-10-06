import AppKit
import Foundation
import WebKit

final class PlayerAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var backend: Process?
    private var isTerminating = false
    private let playerURL = URL(string: "http://127.0.0.1:1985/")!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        buildWindow()
        startBackend()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        stopBackend()
    }

    func windowWillClose(_ notification: Notification) {
        if !isTerminating {
            NSApp.terminate(nil)
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
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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

    private func buildWindow() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        if #available(macOS 10.12.2, *) {
            configuration.mediaTypesRequiringUserActionForPlayback = []
        }

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.loadHTMLString(
            """
            <!doctype html>
            <html>
            <head>
              <meta charset="utf-8">
              <style>
                html,body{margin:0;height:100%;background:#070b10;color:#dbe6f3;
                font:15px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif}
                body{display:flex;align-items:center;justify-content:center}
                .box{text-align:center}.spinner{width:32px;height:32px;margin:0 auto 16px;
                border:3px solid #263548;border-top-color:#ef3340;border-radius:50%;
                animation:s .8s linear infinite}@keyframes s{to{transform:rotate(360deg)}}
              </style>
            </head>
            <body><div class="box"><div class="spinner"></div><div>正在启动本机播放引擎…</div></div></body>
            </html>
            """,
            baseURL: nil
        )

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "海康威视播放器"
        window.minSize = NSSize(width: 980, height: 680)
        window.contentView = webView
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
    }

    private func startBackend() {
        guard let resourceURL = Bundle.main.resourceURL else {
            showFatalError("应用资源目录不存在。")
            return
        }

        let backendURL = resourceURL
            .appendingPathComponent("backend", isDirectory: true)
            .appendingPathComponent("HikvisionLocalPlayer", isDirectory: false)

        guard FileManager.default.isExecutableFile(atPath: backendURL.path) else {
            showFatalError("播放器后台组件缺失或不可执行。")
            return
        }

        let process = Process()
        process.executableURL = backendURL
        process.currentDirectoryURL = backendURL.deletingLastPathComponent()

        var environment = ProcessInfo.processInfo.environment
        environment["HIKVISION_PLAYER_HEADLESS"] = "1"
        process.environment = environment

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        process.terminationHandler = { [weak self] terminated in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.isTerminating && terminated.terminationStatus != 0 {
                    let data = error.fileHandleForReading.readDataToEndOfFile()
                    let detail = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    self.showFatalError(
                        detail?.isEmpty == false
                            ? detail!
                            : "播放器后台服务意外退出（\(terminated.terminationStatus)）。"
                    )
                }
            }
        }

        do {
            try process.run()
            backend = process
            waitForBackend(attempt: 0)
        } catch {
            showFatalError("无法启动播放器后台服务：\(error.localizedDescription)")
        }
    }

    private func waitForBackend(attempt: Int) {
        guard !isTerminating else { return }

        if let backend, !backend.isRunning {
            showFatalError("播放器后台服务启动后立即退出。")
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:1985/api/health")!)
        request.timeoutInterval = 0.8

        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }

            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                DispatchQueue.main.async {
                    self.webView.load(URLRequest(url: self.playerURL))
                }
                return
            }

            if attempt >= 60 {
                DispatchQueue.main.async {
                    self.showFatalError("本机播放服务启动超时。")
                }
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                self.waitForBackend(attempt: attempt + 1)
            }
        }.resume()
    }

    private func stopBackend() {
        guard let process = backend, process.isRunning else {
            backend = nil
            return
        }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:1985/api/shutdown")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 1.0

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1.2)

        var deadline = Date().addingTimeInterval(3.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            deadline = Date().addingTimeInterval(1.0)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        if process.isRunning {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/bin/kill")
            kill.arguments = ["-KILL", String(process.processIdentifier)]
            try? kill.run()
            kill.waitUntilExit()
        }

        backend = nil
    }

    private func showFatalError(_ message: String) {
        guard !isTerminating else { return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "海康威视播放器"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFatalError("播放器界面加载失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFatalError("播放器界面加载失败：\(error.localizedDescription)")
    }
}

let application = NSApplication.shared
let delegate = PlayerAppDelegate()
application.delegate = delegate
application.run()
