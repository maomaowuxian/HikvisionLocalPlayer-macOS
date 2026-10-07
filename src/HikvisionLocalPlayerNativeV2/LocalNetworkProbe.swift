import Foundation
import Network

private final class OneShotCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func run(_ block: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        block()
    }
}

enum LocalNetworkProbe {
    static func check(host: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let once = OneShotCompletion()
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: 80),
                using: .tcp
            )

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run {
                        connection.cancel()
                        continuation.resume()
                    }

                case .failed(let error):
                    if case let .posix(code) = error, code == .ECONNREFUSED {
                        once.run {
                            connection.cancel()
                            continuation.resume()
                        }
                    } else {
                        once.run {
                            connection.cancel()
                            continuation.resume(
                                throwing: AppError.localNetwork(
                                    "无法访问录像机所在的本地网络（\(error)）。请在“系统设置 → 隐私与安全性 → 本地网络”中允许海康威视播放器。"
                                )
                            )
                        }
                    }

                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 15) {
                once.run {
                    connection.cancel()
                    continuation.resume(
                        throwing: AppError.localNetwork(
                            "等待本地网络访问超时。请检查录像机地址，并确认 macOS 已允许海康威视播放器访问本地网络。"
                        )
                    )
                }
            }
        }
    }
}
