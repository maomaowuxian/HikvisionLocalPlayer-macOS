import Foundation

final class Go2RtcController {
    private let apiBase = URL(string: "http://127.0.0.1:1984")!
    private let session: URLSession
    private var process: Process?
    private var ownsProcess = false

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 15
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func start() async throws {
        if await isHealthy() { return }

        try FileManager.default.createDirectory(
            at: AppPaths.runtimeDirectory,
            withIntermediateDirectories: true
        )

        guard let executable = Bundle.main.resourceURL?
            .appendingPathComponent("go2rtc"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AppError.engine("内置 go2rtc 播放引擎缺失或不可执行。")
        }

        let configURL = AppPaths.runtimeDirectory.appendingPathComponent("go2rtc-native-v2.yaml")
        try writeConfig(to: configURL)

        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = AppPaths.runtimeDirectory
        process.arguments = ["-config", configURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw AppError.engine("无法启动 go2rtc：\(error.localizedDescription)")
        }

        self.process = process
        ownsProcess = true

        for _ in 0..<60 {
            if !process.isRunning {
                throw AppError.engine("go2rtc 启动后立即退出，可能是本机 1984 端口被占用。")
            }

            if await isHealthy() {
                return
            }

            try await Task.sleep(nanoseconds: 150_000_000)
        }

        throw AppError.engine("go2rtc 启动超时。")
    }

    func isHealthy() async -> Bool {
        do {
            let url = apiBase.appendingPathComponent("api")
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func configureAndProbe(streamId: String, sourceURL: String) async -> Bool {
        do {
            var patchComponents = URLComponents(
                url: apiBase.appendingPathComponent("api/streams"),
                resolvingAgainstBaseURL: false
            )!
            patchComponents.queryItems = [
                URLQueryItem(name: "name", value: streamId),
                URLQueryItem(name: "src", value: sourceURL)
            ]

            guard let patchURL = patchComponents.url else { return false }
            var patchRequest = URLRequest(url: patchURL)
            patchRequest.httpMethod = "PATCH"
            patchRequest.timeoutInterval = 12

            let (_, patchResponse) = try await session.data(for: patchRequest)
            guard let patchHTTP = patchResponse as? HTTPURLResponse,
                  (200..<300).contains(patchHTTP.statusCode) else {
                return false
            }

            var probeComponents = URLComponents(
                url: apiBase.appendingPathComponent("api/streams"),
                resolvingAgainstBaseURL: false
            )!
            probeComponents.queryItems = [
                URLQueryItem(name: "src", value: streamId),
                URLQueryItem(name: "video", value: "all"),
                URLQueryItem(name: "audio", value: "all")
            ]

            guard let probeURL = probeComponents.url else { return false }
            var probeRequest = URLRequest(url: probeURL)
            probeRequest.timeoutInterval = 12

            let (_, probeResponse) = try await session.data(for: probeRequest)
            guard let probeHTTP = probeResponse as? HTTPURLResponse else {
                return false
            }
            return (200..<300).contains(probeHTTP.statusCode)
        } catch {
            return false
        }
    }

    func deleteStream(_ streamId: String) async {
        do {
            var components = URLComponents(
                url: apiBase.appendingPathComponent("api/streams"),
                resolvingAgainstBaseURL: false
            )!
            components.queryItems = [
                URLQueryItem(name: "src", value: streamId)
            ]

            guard let url = components.url else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.timeoutInterval = 5
            _ = try await session.data(for: request)
        } catch {
        }
    }

    func deleteAllKnownStreams() async {
        await deleteStream("hik_local_player")
        for index in 1...4 {
            await deleteStream("hik_grid_\(index)")
        }
    }

    func hlsURL(for streamId: String) -> URL {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("api/stream.m3u8"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "src", value: streamId)
        ]
        return components.url!
    }

    func shutdownSynchronously() {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            await deleteAllKnownStreams()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2)

        if ownsProcess, let process, process.isRunning {
            process.terminate()

            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }

            if process.isRunning {
                let kill = Process()
                kill.executableURL = URL(fileURLWithPath: "/bin/kill")
                kill.arguments = ["-KILL", String(process.processIdentifier)]
                try? kill.run()
                kill.waitUntilExit()
            }
        }

        process = nil
        ownsProcess = false
        session.invalidateAndCancel()
    }

    private func writeConfig(to url: URL) throws {
        let config = """
        api:
          listen: "127.0.0.1:1984"
          origin: "*"

        rtsp:
          listen: "127.0.0.1:8554"

        webrtc:
          listen: "127.0.0.1:8555"
          candidates:
            - "127.0.0.1:8555"

        log:
          format: text
          level: warn

        streams: {}
        """

        try config.write(to: url, atomically: true, encoding: .utf8)
    }
}
