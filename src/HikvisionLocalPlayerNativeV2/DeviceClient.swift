import Foundation

private final class CredentialSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential

    init(username: String, password: String) {
        credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod

        if (method == NSURLAuthenticationMethodHTTPDigest ||
            method == NSURLAuthenticationMethodHTTPBasic),
           challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, credential)
            return
        }

        if challenge.previousFailureCount > 0 {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        completionHandler(.performDefaultHandling, nil)
    }
}

private final class ChannelXMLParserDelegate: NSObject, XMLParserDelegate {
    private let acceptedContainers: Set<String>
    private var containerDepth = 0
    private var currentElement = ""
    private var text = ""
    private(set) var ids: [Int] = []

    init(acceptedContainers: Set<String>) {
        self.acceptedContainers = acceptedContainers
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if acceptedContainers.contains(elementName) {
            containerDepth += 1
        }
        currentElement = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if containerDepth > 0 && currentElement == "id" {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if containerDepth > 0 && elementName == "id",
           let id = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           id > 0 {
            ids.append(id)
        }

        if acceptedContainers.contains(elementName) {
            containerDepth = max(0, containerDepth - 1)
        }

        currentElement = ""
        text = ""
    }
}

private final class SimpleXMLValueParserDelegate: NSObject, XMLParserDelegate {
    private let targets: Set<String>
    private var currentElement = ""
    private var text = ""
    private(set) var values: [String: String] = [:]

    init(targets: Set<String>) {
        self.targets = targets
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if targets.contains(currentElement) {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if targets.contains(elementName) {
            values[elementName] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        currentElement = ""
        text = ""
    }
}

final class DeviceClient {
    func discoverChannels(
        host rawHost: String,
        username: String,
        password: String
    ) async throws -> [Int] {
        let host = Self.cleanHost(rawHost)
        guard Self.isReasonableHost(host) else { throw AppError.invalidHost }
        guard !username.isEmpty, !password.isEmpty else { throw AppError.missingCredentials }

        let delegate = CredentialSessionDelegate(username: username, password: password)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 7
        config.timeoutIntervalForResource = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCredentialStorage = nil

        let session = URLSession(
            configuration: config,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        try await probeCredentials(
            session: session,
            host: host
        )

        let endpoints: [(path: String, node: String)] = [
            ("/ISAPI/System/Video/inputs/channels", "VideoInputChannel"),
            ("/ISAPI/ContentMgmt/InputProxy/channels", "InputProxyChannel")
        ]

        var ids: [Int] = []
        var failures: [String] = []

        for endpoint in endpoints {
            do {
                let (data, response) = try await get(
                    session: session,
                    urlString: "http://\(host)\(endpoint.path)"
                )

                guard (200..<300).contains(response.statusCode) else {
                    failures.append("\(endpoint.path)：HTTP \(response.statusCode)")
                    continue
                }

                let parserDelegate = ChannelXMLParserDelegate(
                    acceptedContainers: [endpoint.node]
                )
                let parser = XMLParser(data: data)
                parser.delegate = parserDelegate

                guard parser.parse() else {
                    failures.append("\(endpoint.path)：XML 解析失败")
                    continue
                }

                ids.append(contentsOf: parserDelegate.ids)
            } catch {
                failures.append("\(endpoint.path)：\(Self.friendlyNetworkMessage(error))")
            }
        }

        let unique = Array(Set(ids)).sorted()
        if !unique.isEmpty { return unique }

        if !failures.isEmpty {
            throw AppError.device(
                "认证已通过，但无法读取录像机通道：" + failures.joined(separator: "；")
            )
        }

        throw AppError.noChannels
    }

    private func probeCredentials(
        session: URLSession,
        host: String
    ) async throws {
        do {
            let (data, response) = try await get(
                session: session,
                urlString: "http://\(host)/ISAPI/Security/userCheck"
            )

            guard (200..<300).contains(response.statusCode) else {
                throw AppError.authentication(
                    Self.authenticationFailureMessage(
                        statusCode: response.statusCode,
                        data: data
                    )
                )
            }
        } catch let error as AppError {
            throw error
        } catch {
            let message = Self.friendlyNetworkMessage(error)
            if message.contains("取消") || message.contains("authentication") {
                throw AppError.authentication("录像机身份验证失败，请检查用户名和密码。")
            }
            throw AppError.device(message)
        }
    }

    private func get(
        session: URLSession,
        urlString: String
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw AppError.invalidHost
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 7
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AppError.device("录像机返回了无效的 HTTP 响应。")
        }
        return (data, http)
    }

    static func cleanHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("http://") {
            value.removeFirst(7)
        } else if value.lowercased().hasPrefix("https://") {
            value.removeFirst(8)
        }

        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }

        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isReasonableHost(_ host: String) -> Bool {
        !host.isEmpty &&
        !host.contains(" ") &&
        !host.contains("/") &&
        host.count <= 255
    }

    static func buildRtspURL(
        host: String,
        username: String,
        password: String,
        deviceChannelId: Int,
        stream: StreamChoice
    ) -> String {
        let trackId = deviceChannelId * 100 + stream.trackSuffix
        let user = encodeUserInfo(username)
        let pass = encodeUserInfo(password)
        return "rtsp://\(user):\(pass)@\(host):554/PSIA/streaming/channels/\(trackId)"
    }

    private static func encodeUserInfo(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func authenticationFailureMessage(
        statusCode: Int,
        data: Data
    ) -> String {
        let delegate = SimpleXMLValueParserDelegate(
            targets: ["lockStatus", "unlockTime", "retryLoginTime"]
        )
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        _ = parser.parse()

        var message = "录像机身份验证失败（HTTP \(statusCode)）。"
        let lockStatus = delegate.values["lockStatus"]?.lowercased()

        if lockStatus == "lock" || lockStatus == "locked" {
            message += " 当前访问端已被录像机锁定"
            if let value = delegate.values["unlockTime"],
               let seconds = Int(value),
               seconds > 0 {
                message += "，预计 \(seconds) 秒后解锁"
            }
            message += "。锁定期间请不要连续重试。"
            return message
        }

        if let retry = delegate.values["retryLoginTime"], !retry.isEmpty {
            message += " 剩余允许尝试次数=\(retry)。"
        }
        return message
    }

    static func friendlyNetworkMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "连接录像机超时。"
            case .notConnectedToInternet,
                 .cannotFindHost,
                 .cannotConnectToHost,
                 .networkConnectionLost:
                return "无法连接录像机（\(urlError.localizedDescription)）。"
            case .userAuthenticationRequired,
                 .userCancelledAuthentication:
                return "录像机身份验证失败，请检查用户名和密码。"
            default:
                return "连接录像机失败（\(urlError.localizedDescription)）。"
            }
        }
        return error.localizedDescription
    }
}
