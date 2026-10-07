import AppKit
import AVFoundation
import QuartzCore

final class VideoTileView: NSView {
    private let stream: ConnectedStream
    private var displayLayer = AVSampleBufferDisplayLayer()
    private let labelBackground = NSView()
    private let liveDot = NSView()
    private let labelField = NSTextField(labelWithString: "")

    private var client: RTSPH264Client?
    private var isStopped = false
    private var isPaused = false
    private var enqueuedFrameCount = 0
    private var generation = 0
    private var waitingForKeyframe = true
    private let showLabel: Bool
    private var reconnectWork: DispatchWorkItem?
    private var reconnectAttempt = 0
    private var connectionFrameCount = 0

    init(stream: ConnectedStream, showLabel: Bool, initiallyPaused: Bool) {
        self.stream = stream
        self.showLabel = showLabel
        self.isPaused = initiallyPaused
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        labelBackground.wantsLayer = true
        labelBackground.layer?.backgroundColor = PlayerTheme.input.withAlphaComponent(0.88).cgColor
        labelBackground.layer?.borderWidth = 1
        labelBackground.layer?.borderColor = PlayerTheme.border.cgColor
        labelBackground.layer?.cornerRadius = 6
        labelBackground.isHidden = !showLabel
        addSubview(labelBackground)

        labelField.stringValue = stream.label
        labelField.textColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        labelField.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        labelField.lineBreakMode = .byTruncatingTail
        labelField.maximumNumberOfLines = 1
        labelField.isHidden = !showLabel
        labelBackground.addSubview(labelField)
        liveDot.wantsLayer = true
        liveDot.layer?.backgroundColor = PlayerTheme.red.cgColor
        liveDot.layer?.cornerRadius = 3
        labelBackground.addSubview(liveDot)

        startClient()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds

        if !labelBackground.isHidden {
            let maxWidth = max(120, min(bounds.width - 20, 240))
            let height: CGFloat = 26
            labelBackground.frame = NSRect(
                x: 10,
                y: max(8, bounds.height - height - 10),
                width: maxWidth,
                height: height
            )
            liveDot.frame = NSRect(x: 9, y: 10, width: 6, height: 6)
            labelField.frame = NSRect(
                x: 23,
                y: 4,
                width: maxWidth - 32,
                height: 18
            )
        }
    }

    func pause() {
        guard !isStopped, !isPaused else { return }
        isPaused = true
        generation += 1
        reconnectWork?.cancel()
        reconnectWork = nil
        client?.stop()
        client = nil
        displayLayer.flush()
        NSLog("RTSP %@ suspended", stream.streamId)
    }

    func resume() {
        guard !isStopped, isPaused else { return }
        isPaused = false
        resetDisplayLayer()
        startClient()
        NSLog("RTSP %@ resumed", stream.streamId)
    }

    private func resetDisplayLayer() {
        displayLayer.flushAndRemoveImage()
        displayLayer.removeFromSuperlayer()
        displayLayer = AVSampleBufferDisplayLayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
        displayLayer.frame = bounds
        layer?.insertSublayer(displayLayer, at: 0)
        waitingForKeyframe = true
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        generation += 1
        reconnectWork?.cancel()
        reconnectWork = nil
        client?.stop()
        client = nil
        displayLayer.flushAndRemoveImage()
    }

    private func startClient() {
        guard !isStopped, !isPaused else { return }

        generation += 1
        let activeGeneration = generation
        connectionFrameCount = 0
        waitingForKeyframe = true
        let newClient = RTSPH264Client(
            streamId: stream.streamId,
            onSample: { [weak self] sampleBuffer, isKeyframe in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isStopped,
                          !self.isPaused,
                          self.generation == activeGeneration else { return }

                    if self.displayLayer.status == .failed ||
                        self.displayLayer.requiresFlushToResumeDecoding {
                        self.resetDisplayLayer()
                    }
                    guard !self.waitingForKeyframe || isKeyframe else { return }
                    guard self.displayLayer.isReadyForMoreMediaData else {
                        // Dropping a compressed reference frame invalidates later P frames.
                        self.displayLayer.flush()
                        self.waitingForKeyframe = true
                        return
                    }
                    if self.waitingForKeyframe {
                        self.waitingForKeyframe = false
                        self.labelField.stringValue = self.stream.label
                        self.labelBackground.isHidden = !self.showLabel
                        self.labelField.isHidden = !self.showLabel
                        NSLog("RTSP %@ resumed at keyframe generation=%d", self.stream.streamId, activeGeneration)
                    }
                    do {
                        self.displayLayer.enqueue(sampleBuffer)
                        self.enqueuedFrameCount += 1
                        self.connectionFrameCount += 1
                        if self.connectionFrameCount >= 750 { self.reconnectAttempt = 0 }
                        if self.enqueuedFrameCount % 100 == 0 {
                            NSLog(
                                "RTSP %@ enqueued frames=%d status=%ld",
                                self.stream.streamId,
                                self.enqueuedFrameCount,
                                self.displayLayer.status.rawValue
                            )
                        }
                    }
                }
            },
            onError: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self,
                          !self.isStopped,
                          !self.isPaused,
                          self.generation == activeGeneration else { return }
                    NSLog("RTSP %@ error: %@", self.stream.streamId, message)
                    self.scheduleReconnect()
                }
            }
        )

        client = newClient
        newClient.start()
    }

    private func scheduleReconnect() {
        guard !isStopped, !isPaused else { return }
        generation += 1
        let retryGeneration = generation
        client?.stop()
        client = nil
        reconnectWork?.cancel()
        reconnectAttempt = min(reconnectAttempt + 1, 5)
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        showError("连接中断，\(Int(delay)) 秒后重连")
        NSLog("RTSP %@ retry in %.0fs", stream.streamId, delay)
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped, !self.isPaused,
                  self.generation == retryGeneration else { return }
            self.reconnectWork = nil
            self.resetDisplayLayer()
            self.startClient()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showError(_ text: String) {
        labelBackground.isHidden = false
        labelField.isHidden = false
        labelField.stringValue = text
        needsLayout = true
    }
}

final class PlayerGridView: NSView {
    private var tiles: [VideoTileView] = []
    private var isPaused = false
    private let emptyLabel = NSTextField(labelWithString: "等待连接录像机")
    private let unconfiguredLabel = NSTextField(labelWithString: "＋  未配置通道")

    var currentLayout: LayoutChoice = .single {
        didSet { needsLayout = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = PlayerTheme.canvas.cgColor

        emptyLabel.textColor = PlayerTheme.muted
        emptyLabel.font = NSFont.systemFont(ofSize: 16, weight: .medium)
        emptyLabel.alignment = .center
        addSubview(emptyLabel)
        unconfiguredLabel.font = NSFont.systemFont(ofSize: 12)
        unconfiguredLabel.textColor = PlayerTheme.muted
        unconfiguredLabel.alignment = .center
        unconfiguredLabel.isHidden = true
        addSubview(unconfiguredLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        emptyLabel.frame = NSRect(
            x: 20,
            y: max(20, (bounds.height - 24) / 2),
            width: max(0, bounds.width - 40),
            height: 24
        )

        unconfiguredLabel.isHidden = currentLayout != .grid4 || tiles.isEmpty || tiles.count >= 4
        guard !tiles.isEmpty else { return }

        switch currentLayout {
        case .single:
            tiles[0].frame = bounds
            for tile in tiles.dropFirst() {
                tile.frame = .zero
            }

        case .grid4:
            let gap: CGFloat = 2
            let cellWidth = max(0, (bounds.width - gap) / 2)
            let cellHeight = max(0, (bounds.height - gap) / 2)

            let frames = [
                NSRect(
                    x: 0,
                    y: cellHeight + gap,
                    width: cellWidth,
                    height: cellHeight
                ),
                NSRect(
                    x: cellWidth + gap,
                    y: cellHeight + gap,
                    width: cellWidth,
                    height: cellHeight
                ),
                NSRect(
                    x: 0,
                    y: 0,
                    width: cellWidth,
                    height: cellHeight
                ),
                NSRect(
                    x: cellWidth + gap,
                    y: 0,
                    width: cellWidth,
                    height: cellHeight
                )
            ]

            unconfiguredLabel.frame = NSRect(x: cellWidth + gap,
                y: (cellHeight - 20) / 2, width: cellWidth, height: 20)
            for (index, tile) in tiles.enumerated() {
                tile.frame = index < frames.count ? frames[index] : .zero
            }
        }
    }

    func setStreams(
        _ streams: [ConnectedStream],
        engine: Go2RtcController,
        layout: LayoutChoice
    ) {
        clearPlayers()
        currentLayout = layout
        emptyLabel.isHidden = !streams.isEmpty

        for stream in streams {
            let tile = VideoTileView(
                stream: stream,
                showLabel: layout == .grid4,
                initiallyPaused: isPaused
            )
            addSubview(tile)
            tiles.append(tile)
        }

        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func clearPlayers() {
        for tile in tiles {
            tile.stop()
            tile.removeFromSuperview()
        }
        tiles.removeAll()
        emptyLabel.isHidden = false
        needsLayout = true
    }

    func pauseAll() {
        isPaused = true
        tiles.forEach { $0.pause() }
    }

    func resumeAll() {
        isPaused = false
        tiles.forEach { $0.resume() }
    }

    var hasPlayers: Bool {
        !tiles.isEmpty
    }
}
