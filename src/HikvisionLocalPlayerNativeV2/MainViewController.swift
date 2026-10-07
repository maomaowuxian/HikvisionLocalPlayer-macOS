import AppKit

@MainActor
final class MainViewController: NSViewController {
    private let engine: Go2RtcController
    private let device = DeviceClient()
    private let settingsStore = SettingsStore()

    private let playerGrid = PlayerGridView()
    private let hostField = NSTextField()
    private let usernameField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let channelPopup = NSPopUpButton()
    private let layoutControl = PlayerSegmentedControl(
        labels: ["单画面", "四画面"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let streamControl = PlayerSegmentedControl(
        labels: ["子码流", "主码流"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let rememberCheckbox = NSButton(
        checkboxWithTitle: "在这台电脑上记住密码",
        target: nil,
        action: nil
    )

    private let discoverButton = PlayerButton(title: "读取通道", target: nil, action: nil)
    private let connectButton = PlayerButton(title: "连接并播放", target: nil, action: nil)
    private let stopButton = PlayerButton(title: "停止播放", target: nil, action: nil)
    private let refreshButton = PlayerButton(title: "刷新画面", target: nil, action: nil)
    private let fullscreenButton = PlayerButton(title: "全屏", target: nil, action: nil)
    private let settingsToggleButton = PlayerButton(title: "隐藏设置", target: nil, action: nil)

    private let engineStatusLabel = NSTextField(labelWithString: "播放引擎正在启动…")
    private let streamStatusLabel = NSTextField(labelWithString: "尚未连接")
    private let connectionDetailLabel = NSTextField(labelWithString: "本机原生硬件解码 · 数据不会上传到互联网")
    private let messageLabel = NSTextField(wrappingLabelWithString: "播放器已准备就绪。")

    private let settingsPanel = NSView()
    private let contentStack = NSStackView()
    private let topBar = NSView()
    private var topBarHeight: NSLayoutConstraint!
    private var contentTop: NSLayoutConstraint!
    private var contentLeading: NSLayoutConstraint!
    private var contentTrailing: NSLayoutConstraint!
    private var contentBottom: NSLayoutConstraint!
    private var isFullscreenLayout = false
    private var settingsHiddenBeforeFullscreen = false

    private var channelIds: [Int] = []
    private var currentStreams: [ConnectedStream] = []
    private var engineReady = false
    private var isBusy = false

    init(engine: Go2RtcController) {
        self.engine = engine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = PlayerTheme.canvas.cgColor
        root.appearance = NSAppearance(named: .darkAqua)
        view = root
        buildUI()
        restoreSettings()
        startEngine()
    }

    func pausePlayback() {
        playerGrid.pauseAll()
    }

    func resumePlayback() {
        playerGrid.resumeAll()
    }

    func prepareForTermination() {
        playerGrid.clearPlayers()
        currentStreams.removeAll()
    }

    private func buildUI() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = PlayerTheme.canvas.cgColor
        view.addSubview(topBar)

        let brandTitle = makeLabel(
            "海康威视播放器",
            size: 21,
            weight: .semibold,
            color: .white
        )
        let brandSub = makeLabel(
            "HIKVISION LOCAL VIEW",
            size: 10,
            weight: .medium,
            color: PlayerTheme.red
        )

        let brandStack = NSStackView(views: [brandSub, brandTitle])
        brandStack.orientation = .vertical
        brandStack.alignment = .leading
        brandStack.spacing = 3
        brandStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(brandStack)

        let brandBadge = makeLabel("H", size: 29, weight: .bold, color: .white)
        brandBadge.alignment = .center
        brandBadge.wantsLayer = true
        brandBadge.layer?.backgroundColor = PlayerTheme.red.cgColor
        brandBadge.layer?.cornerRadius = 8
        brandBadge.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(brandBadge)

        let headerLine = NSView()
        headerLine.wantsLayer = true
        headerLine.layer?.backgroundColor = PlayerTheme.border.cgColor
        headerLine.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(headerLine)

        engineStatusLabel.wantsLayer = true
        engineStatusLabel.layer?.backgroundColor = PlayerTheme.panel.cgColor
        engineStatusLabel.layer?.cornerRadius = 14
        engineStatusLabel.alignment = .center
        engineStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        engineStatusLabel.textColor = PlayerTheme.secondary
        engineStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(engineStatusLabel)

        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 20
        contentStack.distribution = .fill
        contentStack.detachesHiddenViews = true
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(contentStack)

        let viewerCard = buildViewerCard()
        buildSettingsPanel()

        contentStack.addArrangedSubview(viewerCard)
        contentStack.addArrangedSubview(settingsPanel)

        settingsPanel.widthAnchor.constraint(equalToConstant: 354).isActive = true
        viewerCard.setContentHuggingPriority(.defaultLow, for: .horizontal)
        viewerCard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        topBarHeight = topBar.heightAnchor.constraint(equalToConstant: 88)
        contentTop = contentStack.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 18)
        contentLeading = contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20)
        contentTrailing = contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20)
        contentBottom = contentStack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBarHeight,

            brandStack.leadingAnchor.constraint(equalTo: brandBadge.trailingAnchor, constant: 16),
            brandStack.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            engineStatusLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -24),
            engineStatusLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            engineStatusLabel.widthAnchor.constraint(equalToConstant: 170),
            engineStatusLabel.heightAnchor.constraint(equalToConstant: 30),
            brandBadge.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 24),
            brandBadge.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            brandBadge.widthAnchor.constraint(equalToConstant: 42),
            brandBadge.heightAnchor.constraint(equalToConstant: 42),
            headerLine.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 20),
            headerLine.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -20),
            headerLine.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            headerLine.heightAnchor.constraint(equalToConstant: 1),

            contentTop, contentLeading, contentTrailing, contentBottom
        ])
    }

    private func buildViewerCard() -> NSView {
        let card = panelView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(toolbar)

        let liveTitle = makeLabel(
            "实时预览",
            size: 14,
            weight: .semibold,
            color: .white
        )
        liveTitle.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(liveTitle)
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = PlayerTheme.toolbar.cgColor
        let liveDot = NSView()
        liveDot.wantsLayer = true
        liveDot.layer?.backgroundColor = PlayerTheme.red.cgColor
        liveDot.layer?.cornerRadius = 4
        liveDot.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(liveDot)

        streamStatusLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        streamStatusLabel.textColor = PlayerTheme.muted
        streamStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(streamStatusLabel)

        refreshButton.target = self
        refreshButton.action = #selector(refreshPressed)
        styleSecondaryButton(refreshButton)

        fullscreenButton.target = self
        fullscreenButton.action = #selector(fullscreenPressed)
        styleSecondaryButton(fullscreenButton)

        settingsToggleButton.target = self
        settingsToggleButton.action = #selector(settingsTogglePressed)
        styleSecondaryButton(settingsToggleButton)

        let actions = NSStackView(views: [refreshButton, fullscreenButton, settingsToggleButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        actions.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(actions)

        playerGrid.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(playerGrid)

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(footer)

        connectionDetailLabel.font = NSFont.systemFont(ofSize: 11)
        connectionDetailLabel.textColor = PlayerTheme.muted
        connectionDetailLabel.lineBreakMode = .byTruncatingMiddle
        connectionDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(connectionDetailLabel)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: card.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),

            liveDot.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            liveDot.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 8),
            liveDot.heightAnchor.constraint(equalToConstant: 8),
            liveTitle.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 8),
            liveTitle.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            streamStatusLabel.leadingAnchor.constraint(equalTo: liveTitle.trailingAnchor, constant: 14),
            streamStatusLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            actions.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            playerGrid.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            playerGrid.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            playerGrid.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            playerGrid.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 42),

            connectionDetailLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16),
            connectionDetailLabel.trailingAnchor.constraint(lessThanOrEqualTo: footer.trailingAnchor, constant: -16),
            connectionDetailLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        return card
    }

    private func buildSettingsPanel() {
        settingsPanel.translatesAutoresizingMaskIntoConstraints = false
        settingsPanel.wantsLayer = true
        settingsPanel.layer?.backgroundColor = PlayerTheme.panel.cgColor
        settingsPanel.layer?.cornerRadius = 12
        settingsPanel.layer?.borderWidth = 1
        settingsPanel.layer?.borderColor = PlayerTheme.border.cgColor

        let title = makeLabel("连接录像机", size: 19, weight: .semibold, color: .white)
        let subtitle = makeLabel(
            "DEVICE CONNECTION · v2.0.8",
            size: 10,
            weight: .medium,
            color: PlayerTheme.red
        )

        hostField.placeholderString = "192.168.1.100"
        usernameField.placeholderString = "admin"
        styleInput(hostField)
        styleInput(usernameField)
        styleInput(passwordField)

        layoutControl.selectedSegment = 0
        layoutControl.target = self
        layoutControl.action = #selector(layoutChanged)
        layoutControl.segmentStyle = .texturedRounded

        streamControl.selectedSegment = 0
        streamControl.segmentStyle = .texturedRounded
        streamControl.usesRedSelection = true

        channelPopup.removeAllItems()
        channelPopup.addItem(withTitle: "通道 1")
        channelPopup.bezelStyle = .rounded

        discoverButton.target = self
        discoverButton.action = #selector(discoverPressed)
        styleSecondaryButton(discoverButton)

        connectButton.target = self
        connectButton.action = #selector(connectPressed)
        styleSecondaryButton(connectButton)
        connectButton.primary = true
        connectButton.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        connectButton.keyEquivalent = "\r"

        stopButton.target = self
        stopButton.action = #selector(stopPressed)
        styleSecondaryButton(stopButton)
        stopButton.isEnabled = false

        rememberCheckbox.state = .off
        rememberCheckbox.contentTintColor = PlayerTheme.red
        rememberCheckbox.font = NSFont.systemFont(ofSize: 12)
        rememberCheckbox.attributedTitle = NSAttributedString(
            string: rememberCheckbox.title,
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: PlayerTheme.secondary])

        messageLabel.font = NSFont.systemFont(ofSize: 11)
        messageLabel.textColor = PlayerTheme.secondary
        messageLabel.maximumNumberOfLines = 3

        let channelRow = NSStackView(views: [channelPopup, discoverButton])
        channelRow.orientation = .horizontal
        channelRow.spacing = 8
        channelPopup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let formStack = NSStackView(views: [
            subtitle,
            title,
            spacer(height: 4),
            fieldGroup("录像机地址", hostField),
            fieldGroup("用户名", usernameField),
            fieldGroup("密码", passwordField),
            fieldGroup("画面布局", layoutControl),
            fieldGroup("监控通道", channelRow),
            fieldGroup("播放码流", streamControl),
            rememberCheckbox,
            makeLabel(
                "密码仅保存在 macOS 钥匙串中。",
                size: 10,
                weight: .regular,
                color: PlayerTheme.muted
            )
        ])
        formStack.orientation = .vertical
        formStack.alignment = .leading
        formStack.spacing = 10
        formStack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(formStack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = documentView
        settingsPanel.addSubview(scrollView)

        let buttonStack = NSStackView(views: [connectButton, stopButton])
        buttonStack.orientation = .vertical
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        connectButton.widthAnchor.constraint(equalTo: buttonStack.widthAnchor).isActive = true
        stopButton.widthAnchor.constraint(equalTo: buttonStack.widthAnchor).isActive = true

        let actionArea = NSView()
        actionArea.translatesAutoresizingMaskIntoConstraints = false
        actionArea.wantsLayer = true
        actionArea.layer?.backgroundColor = PlayerTheme.panel.cgColor
        settingsPanel.addSubview(actionArea)
        actionArea.addSubview(messageLabel)
        actionArea.addSubview(buttonStack)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        for arranged in formStack.arrangedSubviews {
            if arranged !== subtitle && arranged !== title {
                arranged.widthAnchor.constraint(equalTo: formStack.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: settingsPanel.topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: settingsPanel.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: settingsPanel.trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: actionArea.topAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            formStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            formStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            formStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            formStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -18),

            actionArea.leadingAnchor.constraint(equalTo: settingsPanel.leadingAnchor, constant: 1),
            actionArea.trailingAnchor.constraint(equalTo: settingsPanel.trailingAnchor, constant: -1),
            actionArea.bottomAnchor.constraint(equalTo: settingsPanel.bottomAnchor, constant: -1),
            actionArea.heightAnchor.constraint(equalToConstant: 132),

            messageLabel.topAnchor.constraint(equalTo: actionArea.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: actionArea.leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(equalTo: actionArea.trailingAnchor, constant: -20),
            messageLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),

            buttonStack.leadingAnchor.constraint(equalTo: actionArea.leadingAnchor, constant: 20),
            buttonStack.trailingAnchor.constraint(equalTo: actionArea.trailingAnchor, constant: -20),
            buttonStack.bottomAnchor.constraint(equalTo: actionArea.bottomAnchor, constant: -12)
        ])

        hostField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        usernameField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        passwordField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        layoutControl.heightAnchor.constraint(equalToConstant: 34).isActive = true
        streamControl.heightAnchor.constraint(equalToConstant: 34).isActive = true
        channelRow.heightAnchor.constraint(equalToConstant: 34).isActive = true
        connectButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stopButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
    }

    private func restoreSettings() {
        let (settings, password) = settingsStore.load()

        hostField.stringValue = settings.host
        usernameField.stringValue = settings.username
        passwordField.stringValue = password
        rememberCheckbox.state = settings.rememberPassword ? .on : .off
        let layoutIndex = settings.layout == .grid4 ? 1 : 0
        layoutControl.setSelected(layoutIndex == 0, forSegment: 0)
        layoutControl.setSelected(layoutIndex == 1, forSegment: 1)
        layoutControl.selectedSegment = layoutIndex

        let streamIndex = settings.stream == .main ? 1 : 0
        streamControl.setSelected(streamIndex == 0, forSegment: 0)
        streamControl.setSelected(streamIndex == 1, forSegment: 1)
        streamControl.selectedSegment = streamIndex

        channelPopup.removeAllItems()
        channelPopup.addItem(withTitle: "通道 \(max(1, settings.channel))")
        channelPopup.selectItem(at: 0)
        updateLayoutControls()
    }

    private func startEngine() {
        Task { @MainActor in
            do {
                try await engine.start()
                engineReady = true
                engineStatusLabel.stringValue = "●  本机播放引擎正常"
                engineStatusLabel.textColor = NSColor(
                    calibratedRed: 0.31,
                    green: 0.82,
                    blue: 0.53,
                    alpha: 1
                )
            } catch {
                engineReady = false
                engineStatusLabel.stringValue = "●  播放引擎启动失败"
                engineStatusLabel.textColor = NSColor(
                    calibratedRed: 0.95,
                    green: 0.35,
                    blue: 0.40,
                    alpha: 1
                )
                setMessage(error.localizedDescription, isError: true)
            }
        }
    }

    @objc private func layoutChanged() {
        updateLayoutControls()
    }

    private func updateLayoutControls() {
        let isGrid = layoutControl.selectedSegment == 1
        channelPopup.isEnabled = !isGrid && !isBusy
        discoverButton.isEnabled = !isBusy
        connectButton.title = isGrid ? "连接四画面" : "连接并播放"
    }

    @objc private func discoverPressed() {
        guard !isBusy else { return }
        let input = currentInput()

        Task { @MainActor in
            do {
                try validate(input)
                setBusy(true)
                setMessage("正在读取录像机通道…")
                try await ensureEngineReady()
                try await LocalNetworkProbe.check(host: input.host)

                let ids = try await device.discoverChannels(
                    host: input.host,
                    username: input.username,
                    password: input.password
                )
                channelIds = ids
                updateChannelPopup(ids: ids, selectedLogicalChannel: input.channel)
                setMessage("已发现 \(ids.count) 路可用监控通道。")
            } catch {
                setMessage(error.localizedDescription, isError: true)
            }
            setBusy(false)
        }
    }

    @objc private func connectPressed() {
        guard !isBusy else { return }
        let input = currentInput()

        Task { @MainActor in
            do {
                try validate(input)
                setBusy(true)
                setMessage("正在连接录像机并准备原生视频…")
                streamStatusLabel.stringValue = "正在连接"

                try await ensureEngineReady()
                try await LocalNetworkProbe.check(host: input.host)

                let ids = try await device.discoverChannels(
                    host: input.host,
                    username: input.username,
                    password: input.password
                )
                channelIds = ids
                updateChannelPopup(ids: ids, selectedLogicalChannel: input.channel)

                await engine.deleteAllKnownStreams()
                playerGrid.clearPlayers()
                currentStreams.removeAll()

                let connected = try await configureStreams(input: input, channelIds: ids)
                guard !connected.isEmpty else { throw AppError.allStreamsFailed }

                currentStreams = connected
                playerGrid.setStreams(
                    connected,
                    engine: engine,
                    layout: input.layout
                )

                var saved = PlayerSettings(
                    host: input.host,
                    username: input.username,
                    channel: input.channel,
                    stream: input.stream,
                    layout: input.layout,
                    rememberPassword: input.rememberPassword,
                    keychainAccount: ""
                )
                if input.layout == .grid4 {
                    saved.channel = 1
                }
                try settingsStore.save(saved, password: input.password)

                refreshButton.isEnabled = true
                stopButton.isEnabled = true

                if input.layout == .grid4 {
                    streamStatusLabel.stringValue = "四画面 · \(connected.count) 路"
                    connectionDetailLabel.stringValue =
                        "\(input.host) · \(connected.count) 路原生硬件解码"
                    let failed = min(4, ids.count) - connected.count
                    let fallback = connected.filter(\.fallbackUsed).count
                    var text = "四画面已连接 \(connected.count) 路。"
                    if failed > 0 { text += " \(failed) 路连接失败。" }
                    if fallback > 0 { text += " \(fallback) 路自动切换到主码流。" }
                    setMessage(text, isError: false)
                } else if let stream = connected.first {
                    streamStatusLabel.stringValue =
                        "通道 \(stream.logicalChannel) · \(stream.stream.displayName)"
                    connectionDetailLabel.stringValue =
                        "\(input.host) · 设备通道 \(stream.deviceChannelId) · 原生硬件解码"
                    setMessage(
                        "通道 \(stream.logicalChannel) 已连接，正在播放\(stream.stream.displayName)。"
                    )
                }
            } catch {
                streamStatusLabel.stringValue = "连接失败"
                setMessage(error.localizedDescription, isError: true)
            }

            setBusy(false)
        }
    }

    @objc private func stopPressed() {
        playerGrid.clearPlayers()
        currentStreams.removeAll()
        streamStatusLabel.stringValue = "已停止"
        connectionDetailLabel.stringValue = "本机原生硬件解码 · 数据不会上传到互联网"
        stopButton.isEnabled = false
        refreshButton.isEnabled = false
        setMessage("实时预览已停止。")

        Task {
            await engine.deleteAllKnownStreams()
        }
    }

    @objc private func refreshPressed() {
        guard !currentStreams.isEmpty else { return }
        let layout: LayoutChoice = layoutControl.selectedSegment == 1 ? .grid4 : .single
        playerGrid.setStreams(currentStreams, engine: engine, layout: layout)
        setMessage("已重新加载实时画面。")
    }

    func setFullscreenLayout(_ fullscreen: Bool) {
        guard isViewLoaded, isFullscreenLayout != fullscreen else { return }
        isFullscreenLayout = fullscreen
        topBar.isHidden = fullscreen
        topBarHeight.constant = fullscreen ? 0 : 88
        contentTop.constant = fullscreen ? 8 : 18
        contentLeading.constant = fullscreen ? 8 : 20
        contentTrailing.constant = fullscreen ? -8 : -20
        contentBottom.constant = fullscreen ? -8 : -20
        if fullscreen {
            settingsHiddenBeforeFullscreen = settingsPanel.isHidden
            settingsPanel.isHidden = true
        } else {
            settingsPanel.isHidden = settingsHiddenBeforeFullscreen
        }
        settingsToggleButton.title = settingsPanel.isHidden ? "显示设置" : "隐藏设置"
        fullscreenButton.title = fullscreen ? "退出全屏" : "全屏"
        view.layoutSubtreeIfNeeded()
        NSLog("Fullscreen layout=%d headerHidden=%d contentTop=%.0f",
              fullscreen ? 1 : 0, topBar.isHidden ? 1 : 0, contentTop.constant)
    }

    @objc private func fullscreenPressed() {
        view.window?.toggleFullScreen(nil)
    }

    @objc private func settingsTogglePressed() {
        settingsPanel.isHidden.toggle()
        settingsToggleButton.title = settingsPanel.isHidden ? "显示设置" : "隐藏设置"
    }

    private func configureStreams(
        input: ConnectionInput,
        channelIds: [Int]
    ) async throws -> [ConnectedStream] {
        let targetDeviceIds: [Int]
        let logicalChannels: [Int]
        let streamIds: [String]

        if input.layout == .grid4 {
            targetDeviceIds = Array(channelIds.prefix(4))
            logicalChannels = Array(1...targetDeviceIds.count)
            streamIds = logicalChannels.map { "hik_grid_\($0)" }
        } else {
            let index = max(0, input.channel - 1)
            guard index < channelIds.count else {
                throw AppError.selectedChannelUnavailable
            }
            targetDeviceIds = [channelIds[index]]
            logicalChannels = [input.channel]
            streamIds = ["hik_local_player"]
        }

        var connected: [ConnectedStream] = []

        for index in targetDeviceIds.indices {
            let deviceId = targetDeviceIds[index]
            let logical = logicalChannels[index]
            let streamId = streamIds[index]

            var activeStream = input.stream
            var fallback = false

            var source = DeviceClient.buildRtspURL(
                host: input.host,
                username: input.username,
                password: input.password,
                deviceChannelId: deviceId,
                stream: activeStream
            )

            var ok = await engine.configureAndProbe(
                streamId: streamId,
                sourceURL: source
            )

            if !ok && activeStream == .sub {
                activeStream = .main
                fallback = true
                source = DeviceClient.buildRtspURL(
                    host: input.host,
                    username: input.username,
                    password: input.password,
                    deviceChannelId: deviceId,
                    stream: activeStream
                )
                ok = await engine.configureAndProbe(
                    streamId: streamId,
                    sourceURL: source
                )
            }

            if ok {
                connected.append(
                    ConnectedStream(
                        logicalChannel: logical,
                        deviceChannelId: deviceId,
                        stream: activeStream,
                        fallbackUsed: fallback,
                        streamId: streamId
                    )
                )
            }
        }

        return connected
    }

    private func currentInput() -> ConnectionInput {
        ConnectionInput(
            host: DeviceClient.cleanHost(hostField.stringValue),
            username: usernameField.stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines),
            password: passwordField.stringValue,
            channel: max(1, channelPopup.indexOfSelectedItem + 1),
            stream: streamControl.selectedSegment == 1 ? .main : .sub,
            layout: layoutControl.selectedSegment == 1 ? .grid4 : .single,
            rememberPassword: rememberCheckbox.state == .on
        )
    }

    private func validate(_ input: ConnectionInput) throws {
        guard DeviceClient.isReasonableHost(input.host) else {
            throw AppError.invalidHost
        }
        guard !input.username.isEmpty, !input.password.isEmpty else {
            throw AppError.missingCredentials
        }
    }

    private func ensureEngineReady() async throws {
        if engineReady { return }
        try await engine.start()
        engineReady = true
        engineStatusLabel.stringValue = "●  本机播放引擎正常"
    }

    private func updateChannelPopup(
        ids: [Int],
        selectedLogicalChannel: Int
    ) {
        channelPopup.removeAllItems()
        for (index, deviceId) in ids.enumerated() {
            channelPopup.addItem(
                withTitle: "通道 \(index + 1)  ·  设备ID \(deviceId)"
            )
        }

        let target = min(max(1, selectedLogicalChannel), max(1, ids.count))
        if !ids.isEmpty {
            channelPopup.selectItem(at: target - 1)
        }
    }

    private func setBusy(_ busy: Bool) {
        isBusy = busy
        hostField.isEnabled = !busy
        usernameField.isEnabled = !busy
        passwordField.isEnabled = !busy
        layoutControl.isEnabled = !busy
        streamControl.isEnabled = !busy
        rememberCheckbox.isEnabled = !busy
        connectButton.isEnabled = !busy
        discoverButton.isEnabled = !busy
        channelPopup.isEnabled = !busy && layoutControl.selectedSegment == 0
    }

    private func setMessage(_ text: String, isError: Bool = false) {
        messageLabel.stringValue = text
        messageLabel.textColor = isError
            ? NSColor(calibratedRed: 0.95, green: 0.48, blue: 0.51, alpha: 1)
            : PlayerTheme.secondary
    }

    private func makeLabel(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        return label
    }

    private func panelView() -> NSView {
        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = PlayerTheme.panel.cgColor
        panel.layer?.masksToBounds = true
        panel.layer?.cornerRadius = 12
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = PlayerTheme.border.cgColor
        return panel
    }

    private func styleInput(_ field: NSTextField) {
        field.cell = field is NSSecureTextField
            ? PlayerSecureTextFieldCell(textCell: "")
            : PlayerTextFieldCell(textCell: "")
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = true
        field.backgroundColor = PlayerTheme.input
        field.textColor = PlayerTheme.text
        field.font = NSFont.systemFont(ofSize: 13)
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.layer?.borderWidth = 1
        field.layer?.borderColor = PlayerTheme.border.cgColor
        field.layer?.masksToBounds = true
    }

    private func styleSecondaryButton(_ button: NSButton) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = PlayerTheme.text
    }

    private func fieldGroup(_ title: String, _ control: NSView) -> NSStackView {
        let label = makeLabel(
            title,
            size: 12,
            weight: .semibold,
            color: PlayerTheme.secondary
        )
        let stack = NSStackView(views: [label, control])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        control.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    private func spacer(height: CGFloat) -> NSView {
        let view = NSView()
        view.heightAnchor.constraint(equalToConstant: height).isActive = true
        return view
    }

    private struct ConnectionInput {
        let host: String
        let username: String
        let password: String
        let channel: Int
        let stream: StreamChoice
        let layout: LayoutChoice
        let rememberPassword: Bool
    }
}
