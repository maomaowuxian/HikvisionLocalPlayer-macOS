import Foundation

final class KeychainStore {
    static let shared = KeychainStore()
    private let service = "io.github.maomaowuxian.hikvisionlocalplayer"

    private init() {}

    func read(account: String) -> String {
        guard !account.isEmpty else { return "" }
        let result = run(
            "find-generic-password",
            "-a", account,
            "-s", service,
            "-w"
        )
        guard result.exitCode == 0 else { return "" }
        return result.standardOutput.trimmingCharacters(in: .newlines)
    }

    func write(account: String, password: String) throws {
        guard !account.isEmpty else { return }

        let result = run(
            "add-generic-password",
            "-U",
            "-a", account,
            "-s", service,
            "-w", password
        )

        guard result.exitCode == 0 else {
            throw AppError.device("无法将录像机密码保存到 macOS 钥匙串。")
        }
    }

    func delete(account: String) {
        guard !account.isEmpty else { return }
        _ = run(
            "delete-generic-password",
            "-a", account,
            "-s", service
        )
    }

    private func run(_ arguments: String...) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            return ProcessResult(exitCode: -1, standardOutput: "")
        }

        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
        }

        if process.isRunning {
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/bin/kill")
            kill.arguments = ["-KILL", String(process.processIdentifier)]
            try? kill.run()
            kill.waitUntilExit()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = error.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private struct ProcessResult {
        let exitCode: Int32
        let standardOutput: String
    }
}

final class SettingsStore {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        try? FileManager.default.createDirectory(
            at: AppPaths.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
    }

    func load() -> (PlayerSettings, String) {
        if let data = try? Data(contentsOf: AppPaths.settingsURL),
           let settings = try? decoder.decode(PlayerSettings.self, from: data) {
            let password = settings.rememberPassword
                ? KeychainStore.shared.read(account: settings.keychainAccount)
                : ""
            return (settings, password)
        }

        return loadLegacy()
    }

    func save(_ settings: PlayerSettings, password: String) throws {
        var settings = settings
        let newAccount = buildKeychainAccount(settings)
        let oldAccount = loadPersistedAccount()

        if settings.rememberPassword && !password.isEmpty {
            if !oldAccount.isEmpty && oldAccount != newAccount {
                KeychainStore.shared.delete(account: oldAccount)
            }
            try KeychainStore.shared.write(account: newAccount, password: password)
            settings.keychainAccount = newAccount
        } else {
            if !oldAccount.isEmpty {
                KeychainStore.shared.delete(account: oldAccount)
            }
            KeychainStore.shared.delete(account: newAccount)
            settings.keychainAccount = ""
        }

        let data = try encoder.encode(settings)
        let temporary = AppPaths.settingsURL.appendingPathExtension("new")
        try data.write(to: temporary, options: .atomic)
        try? FileManager.default.removeItem(at: AppPaths.settingsURL)
        try FileManager.default.moveItem(at: temporary, to: AppPaths.settingsURL)
    }

    private func loadPersistedAccount() -> String {
        guard let data = try? Data(contentsOf: AppPaths.settingsURL),
              let settings = try? decoder.decode(PlayerSettings.self, from: data) else {
            return ""
        }
        return settings.keychainAccount
    }

    private func buildKeychainAccount(_ settings: PlayerSettings) -> String {
        "\(settings.username)@\(settings.host)"
    }

    private func loadLegacy() -> (PlayerSettings, String) {
        var settings = PlayerSettings.defaults
        guard let text = try? String(
            contentsOf: AppPaths.legacySettingsURL,
            encoding: .utf8
        ) else {
            return (settings, "")
        }

        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let index = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<index])
            let value = String(line[line.index(after: index)...])
            values[key] = value
        }

        func decode(_ key: String, fallback: String) -> String {
            guard let encoded = values[key],
                  let data = Data(base64Encoded: encoded),
                  let value = String(data: data, encoding: .utf8) else {
                return fallback
            }
            return value
        }

        settings.host = decode("host", fallback: settings.host)
        settings.username = decode("username", fallback: settings.username)

        if let channel = values["channel"].flatMap(Int.init), channel > 0 {
            settings.channel = channel
        }
        if let choice = StreamChoice(
            rawValue: decode("stream", fallback: settings.stream.rawValue)
        ) {
            settings.stream = choice
        }
        if let layout = LayoutChoice(
            rawValue: decode("layout", fallback: settings.layout.rawValue)
        ) {
            settings.layout = layout
        }
        if let remember = values["remember"].flatMap(Bool.init) {
            settings.rememberPassword = remember
        }
        settings.keychainAccount = decode(
            "keychainAccount",
            fallback: buildKeychainAccount(settings)
        )

        let password = settings.rememberPassword
            ? KeychainStore.shared.read(account: settings.keychainAccount)
            : ""
        return (settings, password)
    }
}
