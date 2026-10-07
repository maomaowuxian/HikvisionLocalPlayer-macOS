import Foundation

enum StreamChoice: String, Codable, CaseIterable {
    case sub
    case main

    var displayName: String {
        switch self {
        case .sub: return "子码流"
        case .main: return "主码流"
        }
    }

    var trackSuffix: Int {
        self == .main ? 1 : 2
    }
}

enum LayoutChoice: String, Codable {
    case single
    case grid4
}

struct PlayerSettings: Codable {
    var host: String = ""
    var username: String = "admin"
    var channel: Int = 1
    var stream: StreamChoice = .sub
    var layout: LayoutChoice = .single
    var rememberPassword: Bool = false
    var keychainAccount: String = ""

    static var defaults: PlayerSettings { PlayerSettings() }
}

struct ConnectedStream {
    let logicalChannel: Int
    let deviceChannelId: Int
    let stream: StreamChoice
    let fallbackUsed: Bool
    let streamId: String

    var label: String {
        var text = "通道 \(logicalChannel) · \(stream.displayName)"
        if fallbackUsed { text += "（自动切换）" }
        return text
    }
}

enum AppPaths {
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return base.appendingPathComponent("HikvisionLocalPlayer", isDirectory: true)
    }

    static var runtimeDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Runtime", isDirectory: true)
    }

    static var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("native-v2-settings.json")
    }

    static var legacySettingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.dat")
    }
}

enum AppError: LocalizedError {
    case invalidHost
    case missingCredentials
    case noChannels
    case selectedChannelUnavailable
    case allStreamsFailed
    case localNetwork(String)
    case authentication(String)
    case device(String)
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            return "请输入正确的录像机地址，例如 192.168.1.100。"
        case .missingCredentials:
            return "请输入录像机用户名和密码。"
        case .noChannels:
            return "录像机没有返回可用通道。"
        case .selectedChannelUnavailable:
            return "所选通道不可用。"
        case .allStreamsFailed:
            return "所选通道均无法建立 RTSP 预览。"
        case .localNetwork(let message),
             .authentication(let message),
             .device(let message),
             .engine(let message):
            return message
        }
    }
}
