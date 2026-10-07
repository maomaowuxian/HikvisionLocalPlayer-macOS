import Foundation
import CoreMedia
import Darwin

final class RTSPH264Client: @unchecked Sendable {
    typealias SampleHandler = @Sendable (CMSampleBuffer, Bool) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let streamId: String
    private let queue: DispatchQueue
    private let onSample: SampleHandler
    private let onError: ErrorHandler

    private let stateLock = NSLock()
    private var socketFD: Int32 = -1
    private var stopping = false
    private var readBuffer = Data()
    private var cseq = 1
    private var sessionId = ""
    // All protocol state below belongs to the receiver queue. No timer writes
    // concurrently to a socket carrying interleaved RTP and RTSP responses.
    private var keepaliveInterval: TimeInterval = 20
    private var nextKeepalive: TimeInterval = 0
    private var pendingKeepalive: (sequence: Int, sentAt: TimeInterval)?
    private var lastVideoSample: TimeInterval = 0
    private var receiving = false
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }


    private var formatDescription: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?

    private var currentTimestamp: UInt32?
    private var accessUnitNALs: [Data] = []
    private var fragmentedNAL: Data?
    private var fragmentedTimestamp: UInt32?

    init(
        streamId: String,
        onSample: @escaping SampleHandler,
        onError: @escaping ErrorHandler
    ) {
        self.streamId = streamId
        self.onSample = onSample
        self.onError = onError
        self.queue = DispatchQueue(
            label: "io.github.maomaowuxian.hikvisionlocalplayer.rtsp.\(streamId)",
            qos: .userInitiated
        )
    }

    func start() {
        stateLock.lock()
        stopping = false
        stateLock.unlock()

        queue.async { [weak self] in
            self?.run()
        }
    }

    func stop() {
        stateLock.lock()
        stopping = true
        let fd = socketFD
        // Wake the reader, but only its owning queue may close the fd.
        // Otherwise a rapid reconnect can reuse the fd while recv/send still runs.
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        stateLock.unlock()
    }

    private var shouldStop: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopping
    }

    private func run() {
        do {
            try connectSocket()
            try performHandshake()
            receiving = true
            lastVideoSample = now
            nextKeepalive = now + keepaliveInterval
            NSLog("RTSP %@ playing; keepalive interval=%.1fs", streamId, keepaliveInterval)
            try receiveLoop()
        } catch {
            if !shouldStop {
                onError(error.localizedDescription)
            }
        }

        receiving = false
        cleanupSocket()
    }

    private func connectSocket() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw AppError.engine("无法创建本机 RTSP 套接字。")
        }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(8554).bigEndian
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            Darwin.close(fd)
            throw AppError.engine("无法解析本机 RTSP 地址。")
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw AppError.engine("无法连接本机 RTSP 服务：\(message)")
        }

        stateLock.lock()
        if stopping {
            stateLock.unlock()
            Darwin.close(fd)
            throw CancellationError()
        }
        socketFD = fd
        stateLock.unlock()
    }

    private func performHandshake() throws {
        let baseURL = "rtsp://127.0.0.1:8554/\(streamId)"

        let describe = try sendRequest(
            method: "DESCRIBE",
            url: baseURL,
            headers: ["Accept": "application/sdp"]
        )
        guard describe.statusCode == 200 else {
            throw AppError.engine("RTSP DESCRIBE 失败：HTTP \(describe.statusCode)")
        }

        try parseSDP(describe.body)

        let control = pendingControl ?? "trackID=0"
        let trackURL: String
        if control.lowercased().hasPrefix("rtsp://") {
            trackURL = control
        } else {
            trackURL = baseURL + "/" + control
        }

        let setup = try sendRequest(
            method: "SETUP",
            url: trackURL,
            headers: [
                "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
            ]
        )
        guard setup.statusCode == 200 else {
            throw AppError.engine("RTSP SETUP 失败：HTTP \(setup.statusCode)")
        }

        if let session = setup.headers["session"] {
            sessionId = session.split(separator: ";", maxSplits: 1).first.map(String.init) ?? session
            for part in session.split(separator: ";").dropFirst() {
                let field = part.trimmingCharacters(in: .whitespaces)
                if field.lowercased().hasPrefix("timeout="),
                   let timeout = TimeInterval(field.dropFirst(8)), timeout > 0 {
                    keepaliveInterval = max(0.2, min(20, timeout / 3))
                }
            }
        }
        guard !sessionId.isEmpty else {
            throw AppError.engine("RTSP SETUP 未返回 Session。")
        }

        let play = try sendRequest(
            method: "PLAY",
            url: baseURL,
            headers: [
                "Session": sessionId,
                "Range": "npt=0.000-"
            ]
        )
        guard play.statusCode == 200 else {
            throw AppError.engine("RTSP PLAY 失败：HTTP \(play.statusCode)")
        }
    }

    private func parseSDP(_ body: Data) throws {
        guard let text = String(data: body, encoding: .utf8) else {
            throw AppError.engine("RTSP SDP 无法解析。")
        }

        var control: String?
        var parameterSets: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("a=control:") {
                control = String(line.dropFirst("a=control:".count))
            }
            if line.hasPrefix("a=fmtp:"),
               let range = line.range(of: "sprop-parameter-sets=") {
                let value = line[range.upperBound...]
                parameterSets = value.split(separator: ";", maxSplits: 1).first.map(String.init)
            }
        }

        guard let parameterSets else {
            throw AppError.engine("RTSP SDP 未提供 H.264 SPS/PPS。")
        }

        let parts = parameterSets.split(separator: ",", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let sps = Data(base64Encoded: parts[0]),
              let pps = Data(base64Encoded: parts[1]) else {
            throw AppError.engine("RTSP SDP 的 H.264 SPS/PPS 无效。")
        }

        self.sps = sps
        self.pps = pps
        try rebuildFormatDescription()

        pendingControl = control
    }

    private var pendingControl: String?

    private struct RTSPResponse {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
        let control: String?
    }

    private func sendRequest(
        method: String,
        url: String,
        headers: [String: String]
    ) throws -> RTSPResponse {
        var request = "\(method) \(url) RTSP/1.0\r\n"
        request += "CSeq: \(cseq)\r\n"
        cseq += 1
        request += "User-Agent: HikvisionLocalPlayer/2.0\r\n"
        for (key, value) in headers {
            request += "\(key): \(value)\r\n"
        }
        request += "\r\n"

        try writeAll(Data(request.utf8))
        var response = try readRTSPResponse()
        if method == "DESCRIBE" {
            response = RTSPResponse(
                statusCode: response.statusCode,
                headers: response.headers,
                body: response.body,
                control: pendingControl
            )
        }
        return response
    }

    private func readRTSPResponse() throws -> RTSPResponse {
        let deadline = now + 10
        while true {
            guard !shouldStop else { throw CancellationError() }
            guard now < deadline else { throw AppError.engine("RTSP 响应超时。") }
            guard readBuffer.count <= 2_097_152 else {
                throw AppError.engine("RTSP 响应超过允许大小。")
            }
            if let headerRange = readBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerEnd = headerRange.upperBound
                let headerData = readBuffer[..<headerEnd]
                guard let headerText = String(data: headerData, encoding: .utf8) else {
                    throw AppError.engine("RTSP 响应头无效。")
                }

                var lines = headerText.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst()
                let parts = statusLine.split(separator: " ")
                let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0

                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let key = line[..<colon]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    let value = line[line.index(after: colon)...]
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    headers[key] = value
                }

                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                guard contentLength >= 0, contentLength <= 1_048_576 else {
                    throw AppError.engine("RTSP Content-Length 无效。")
                }
                let total = headerEnd + contentLength
                if readBuffer.count < total {
                    try receiveMore()
                    continue
                }

                let body = contentLength > 0
                    ? readBuffer.subdata(in: headerEnd..<total)
                    : Data()
                readBuffer.removeSubrange(0..<total)

                return RTSPResponse(
                    statusCode: status,
                    headers: headers,
                    body: body,
                    control: nil
                )
            }

            try receiveMore()
        }
    }

    private func serviceSession() throws {
        guard receiving else { return }
        guard !shouldStop else { throw CancellationError() }
        let currentTime = now
        if currentTime - lastVideoSample > 15 {
            throw AppError.engine("RTSP 连续 15 秒未收到完整视频帧。")
        }
        if let pending = pendingKeepalive {
            if currentTime - pending.sentAt > 10 {
                throw AppError.engine("RTSP 保活响应超时。")
            }
            return
        }
        guard currentTime >= nextKeepalive else { return }
        let sequence = cseq
        cseq += 1
        let request = "OPTIONS rtsp://127.0.0.1:8554/\(streamId) RTSP/1.0\r\n" +
            "CSeq: \(sequence)\r\nSession: \(sessionId)\r\n" +
            "User-Agent: HikvisionLocalPlayer/2.0\r\n\r\n"
        try writeAll(Data(request.utf8))
        pendingKeepalive = (sequence, currentTime)
        nextKeepalive = currentTime + keepaliveInterval
    }

    private func receiveLoop() throws {
        while !shouldStop {
            try serviceSession()
            if readBuffer.isEmpty { try receiveMore() }
            guard !readBuffer.isEmpty else { continue }

            if readBuffer[0] == 0x24 {
                while readBuffer.count < 4 { try receiveMore() }
                let channel = readBuffer[1]
                let length = Int(readBuffer[2]) << 8 | Int(readBuffer[3])
                while readBuffer.count < 4 + length { try receiveMore() }
                let packet = readBuffer.subdata(in: 4..<(4 + length))
                readBuffer.removeSubrange(0..<(4 + length))
                if channel == 0 { processRTP(packet) }
            } else {
                // OPTIONS replies share the TCP byte stream with RTP packets.
                // Consume complete replies without treating them as video.
                let response = try readRTSPResponse()
                if let pending = pendingKeepalive,
                   Int(response.headers["cseq"] ?? "") == pending.sequence {
                    guard response.statusCode == 200 else {
                        throw AppError.engine("RTSP 保活失败：\(response.statusCode)")
                    }
                    pendingKeepalive = nil
                    NSLog("RTSP %@ keepalive acknowledged cseq=%d", streamId, pending.sequence)
                }
            }
        }
    }

    private func processRTP(_ packet: Data) {
        guard packet.count >= 12 else { return }

        let b0 = packet[0]
        let b1 = packet[1]
        let version = b0 >> 6
        guard version == 2 else { return }

        let csrcCount = Int(b0 & 0x0F)
        var offset = 12 + csrcCount * 4
        guard packet.count >= offset else { return }

        if (b0 & 0x10) != 0 {
            guard packet.count >= offset + 4 else { return }
            let extensionWords = Int(packet[offset + 2]) << 8 | Int(packet[offset + 3])
            offset += 4 + extensionWords * 4
            guard packet.count >= offset else { return }
        }

        var payloadEnd = packet.count
        if (b0 & 0x20) != 0, let padding = packet.last, padding > 0 {
            payloadEnd -= Int(padding)
        }
        guard payloadEnd > offset else { return }

        let timestamp =
            UInt32(packet[4]) << 24 |
            UInt32(packet[5]) << 16 |
            UInt32(packet[6]) << 8 |
            UInt32(packet[7])

        let marker = (b1 & 0x80) != 0
        let payload = packet.subdata(in: offset..<payloadEnd)
        guard let first = payload.first else { return }
        let nalType = first & 0x1F

        if let current = currentTimestamp, current != timestamp {
            flushAccessUnit(timestamp: current)
            currentTimestamp = timestamp
        } else if currentTimestamp == nil {
            currentTimestamp = timestamp
        }

        switch nalType {
        case 1...23:
            handleCompleteNAL(payload)

        case 24:
            parseSTAPA(payload)

        case 28:
            parseFUA(payload, timestamp: timestamp)

        default:
            break
        }

        if marker {
            flushAccessUnit(timestamp: timestamp)
            currentTimestamp = nil
        }
    }

    private func handleCompleteNAL(_ nal: Data) {
        guard let typeByte = nal.first else { return }
        let type = typeByte & 0x1F

        if type == 7 {
            sps = nal
            try? rebuildFormatDescription()
            return
        }
        if type == 8 {
            pps = nal
            try? rebuildFormatDescription()
            return
        }

        accessUnitNALs.append(nal)
    }

    private func parseSTAPA(_ payload: Data) {
        guard payload.count >= 3 else { return }
        var offset = 1

        while offset + 2 <= payload.count {
            let length = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard length > 0, offset + length <= payload.count else { break }
            handleCompleteNAL(payload.subdata(in: offset..<(offset + length)))
            offset += length
        }
    }

    private func parseFUA(_ payload: Data, timestamp: UInt32) {
        guard payload.count >= 3 else { return }
        let indicator = payload[0]
        let header = payload[1]
        let start = (header & 0x80) != 0
        let end = (header & 0x40) != 0
        let originalType = header & 0x1F
        let reconstructedHeader = (indicator & 0xE0) | originalType

        if start {
            var data = Data([reconstructedHeader])
            data.append(payload.dropFirst(2))
            fragmentedNAL = data
            fragmentedTimestamp = timestamp
            return
        }

        guard fragmentedTimestamp == timestamp,
              var data = fragmentedNAL else {
            fragmentedNAL = nil
            fragmentedTimestamp = nil
            return
        }

        data.append(payload.dropFirst(2))
        fragmentedNAL = data

        if end {
            handleCompleteNAL(data)
            fragmentedNAL = nil
            fragmentedTimestamp = nil
        }
    }

    private func flushAccessUnit(timestamp: UInt32) {
        guard !accessUnitNALs.isEmpty,
              let formatDescription else {
            accessUnitNALs.removeAll(keepingCapacity: true)
            return
        }

        let containsIDR = accessUnitNALs.contains { ($0.first ?? 0) & 0x1F == 5 }
        var bytes = Data()

        for nal in accessUnitNALs {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
            bytes.append(nal)
        }
        accessUnitNALs.removeAll(keepingCapacity: true)

        var blockBuffer: CMBlockBuffer?
        let createBlock = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard createBlock == kCMBlockBufferNoErr,
              let blockBuffer else { return }

        let copyStatus = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let baseAddress = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: bytes.count
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(
                value: CMTimeValue(timestamp),
                timescale: 90_000
            ),
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytes.count

        let status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr,
              let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ),
           CFArrayGetCount(attachments) > 0,
           let rawDictionary = CFArrayGetValueAtIndex(attachments, 0) {
            let dictionary = unsafeBitCast(
                rawDictionary,
                to: CFMutableDictionary.self
            )

            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_DisplayImmediately
                ).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )

            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(
                    kCMSampleAttachmentKey_NotSync
                ).toOpaque(),
                Unmanaged.passUnretained(
                    containsIDR ? kCFBooleanFalse : kCFBooleanTrue
                ).toOpaque()
            )
        }

        lastVideoSample = now
        onSample(sampleBuffer, containsIDR)
    }

    private func rebuildFormatDescription() throws {
        guard let sps, let pps else { return }

        var description: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!
                ]
                let sizes = [sps.count, pps.count]

                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                    }
                }
            }
        }

        guard status == noErr,
              let videoDescription = description else {
            throw AppError.engine("无法创建 H.264 VideoToolbox 格式描述。")
        }

        formatDescription = videoDescription
    }

    private func receiveMore() throws {
        guard !shouldStop else { throw CancellationError() }
        try serviceSession()
        let fd = currentSocketFD()
        guard fd >= 0 else { throw CancellationError() }

        var storage = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.recv(fd, &storage, storage.count, 0)

        if count > 0 {
            readBuffer.append(storage, count: count)
            return
        }

        if count == 0 {
            throw AppError.engine("本机 RTSP 连接已关闭。")
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
            if shouldStop { throw CancellationError() }
            return
        }

        if shouldStop { throw CancellationError() }
        throw AppError.engine("读取本机 RTSP 失败：\(String(cString: strerror(errno)))")
    }

    private func writeAll(_ data: Data) throws {
        let fd = currentSocketFD()
        guard fd >= 0 else { throw CancellationError() }

        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var remaining = raw.count

            while remaining > 0 {
                guard !shouldStop else { throw CancellationError() }
                let written = Darwin.send(fd, pointer, remaining, 0)
                if written <= 0 {
                    throw AppError.engine("写入本机 RTSP 失败：\(String(cString: strerror(errno)))")
                }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
        }
    }

    private func currentSocketFD() -> Int32 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return socketFD
    }

    private func cleanupSocket() {
        stateLock.lock()
        let fd = socketFD
        socketFD = -1
        stateLock.unlock()

        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}
