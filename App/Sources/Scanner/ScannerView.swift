import AVFoundation
import SwiftUI

/// The Scan tab. One set of controls (batch menu, feeder strip, run summary,
/// shutter) in two arrangements: on the iPhone they float over a full-screen
/// viewfinder; in a Mac window they sit in a side panel beside a viewfinder
/// that shows the camera's whole frame, with the camera picker in the toolbar.
struct ScannerView: View {
    let model: ScannerModel
    let session: AVCaptureSession
    let directory: CardDirectory
    /// Builds the start-run sheet's model, pre-filled from the last run.
    let makeStartRun: () -> StartRunModel
    #if os(macOS)
    /// Which camera the Mac photographs through; the iPhone has only one.
    let cameraSource: CameraSourceModel
    #endif

    @Environment(\.openURL) private var openURL
    @State private var isStartingRun = false
    @State private var previewFrame: CGRect = .zero
    @State private var guideFrame: CGRect = .zero

    var body: some View {
        layout
            .sheet(item: pendingScan) { pending in
                ScanReviewView(
                    record: pending.record,
                    photo: pending.photo,
                    rectified: pending.rectified,
                    directory: directory,
                    onVerdict: { verdict in Task { await model.resolve(verdict) } },
                    onRetake: { model.retake() }
                )
                .interactiveDismissDisabled()
                .sheetSizing(minWidth: 520, minHeight: 680)
            }
            .alert("Scan failed", isPresented: isShowingProblem, presenting: model.problem) { _ in
                Button("OK") { model.dismissProblem() }
            } message: { problem in
                Text(problem.message)
            }
            .alert("Couldn't save", isPresented: isShowingStorageProblem, presenting: model.storageProblem) { _ in
                Button("OK") { model.dismissStorageProblem() }
            } message: { problem in
                Text(problem.message)
            }
            .sheet(isPresented: $isStartingRun) {
                StartRunSheet(model: makeStartRun()) { setup in
                    await model.beginNewBatch(setup)
                }
                .sheetSizing()
            }
            .sensoryFeedback(.success, trigger: model.savedVerdictCount)
            .sensoryFeedback(.success, trigger: model.acceptedCount)
    }

    // MARK: - iPhone

    #if os(iOS)
    private var layout: some View {
        ZStack {
            background
            if model.cameraState == .ready {
                controls
            }
            processingOverlay
        }
        .task { await model.start() }
        .onDisappear { model.stopCamera() }
        .onChange(of: [previewFrame, guideFrame], initial: true) {
            // The card sits inside the guide on the stand; the crop follows it.
            model.guideCrop = guideFrame.isEmpty || previewFrame.isEmpty ? nil : GuideCrop(guideFrame: guideFrame, previewFrame: previewFrame)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch model.cameraState {
        case .ready:
            CameraPreview(session: session)
                .ignoresSafeArea()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previewFrame = $0 }
        case .unknown, .starting:
            Color.black
                .ignoresSafeArea()
                .overlay { ProgressView().tint(.white) }
        case .denied, .noCamera, .disconnected, .unavailable:
            cameraUnavailable
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                batchMenu
                Spacer()
                torchButton
            }
            .padding()

            feederStrip
                .padding(.horizontal)

            Spacer()

            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .aspectRatio(63.0 / 88.0, contentMode: .fit)
                // Measured before the padding: the crop must follow the dashed
                // rectangle itself, not the padded box around it.
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { guideFrame = $0 }
                // On the stand the card shows at about half the screen's width.
                .padding(.horizontal, 100)
                .accessibilityHidden(true)

            Spacer()

            if case .ended(let progress, let reason) = model.autoScan {
                RunCompleteStrip(model: model, progress: progress, reason: reason)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            HStack(alignment: .center) {
                summaryLabel
                Spacer()
                shutterButton
                Spacer()
                // Balances the summary so the shutter stays centred.
                summaryLabel.hidden()
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }
    #endif

    // MARK: - Mac

    #if os(macOS)
    private var layout: some View {
        HStack(spacing: 0) {
            viewfinder
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            sidePanel
                .frame(width: 340)
        }
        .background(Theme.ground)
        .navigationTitle("Scan")
        .toolbar { cameraToolbar }
        .task { await cameraSource.run() }
        // Each change of camera (picked, lost, back) restarts or parks the scanner.
        .task(id: cameraSource.source) { await model.follow(cameraSource.source) }
        .onDisappear { model.stopCamera() }
        .onChange(of: previewFrame, initial: true) { updateGuideCrop() }
        .onChange(of: cameraSource.guide) { updateGuideCrop() }
    }

    /// The preview shows the whole frame, so the guide is placed in it by
    /// `FrameGuide` and the crop follows the guide.
    private func updateGuideCrop() {
        let guide = cameraSource.guide
        model.guideCrop = previewFrame.isEmpty ? nil : GuideCrop(guideFrame: guide.rect(in: previewFrame), previewFrame: previewFrame, margin: guide.cropMargin)
    }

    private var viewfinder: some View {
        ZStack {
            Color.black
            switch model.cameraState {
            case .ready:
                CameraPreview(session: session, rotation: cameraSource.rotation)
                    .aspectRatio(cameraSource.displayAspectRatio ?? 3.0 / 4.0, contentMode: .fit)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { previewFrame = $0 }
                    .overlay { frameGuide }
                    .accessibilityLabel("Camera preview from \(cameraSource.source.device?.name ?? String(localized: "the camera"))")
            case .unknown, .starting:
                ProgressView {
                    Text(cameraSource.source == .searching ? "Looking for cameras…" : "Starting \(cameraSource.source.device?.name ?? String(localized: "the camera"))…")
                }
                .tint(.white)
                .foregroundStyle(.white)
            case .denied, .noCamera, .disconnected, .unavailable:
                cameraUnavailable
            }
            processingOverlay
        }
    }

    /// The dashed card outline, where `FrameGuide` puts it in the frame.
    private var frameGuide: some View {
        GeometryReader { proxy in
            let rect = cameraSource.guide.rect(in: CGRect(origin: .zero, size: proxy.size))
            RoundedRectangle(cornerRadius: rect.width * 0.07)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
        }
        .accessibilityHidden(true)
    }

    private var sidePanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                batchMenu
                    .frame(maxWidth: .infinity, alignment: .leading)
                cameraSettings
                feederStrip
                if case .ended(let progress, let reason) = model.autoScan {
                    RunCompleteStrip(model: model, progress: progress, reason: reason)
                }
                HStack(alignment: .center) {
                    summaryLabel
                    Spacer()
                    shutterButton
                }
                Text("Space takes a photo · ⌘↩ feeds and scans · ⌘. stops feeding")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding()
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
    }

    @ToolbarContentBuilder
    private var cameraToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            CameraPicker(source: cameraSource)
            rotateButton
            if cameraSource.source.device?.hasTorch == true {
                torchButton
            }
        }
    }

    private var rotateButton: some View {
        Button {
            Task { await cameraSource.rotateClockwise() }
        } label: {
            Label("Rotate", systemImage: "rotate.right")
        }
        .disabled(cameraSource.source.device == nil)
        .keyboardShortcut("r", modifiers: [.command, .option])
        .help("Turn the picture a quarter-turn clockwise, for a card that shows sideways (⌥⌘R)")
    }

    /// Fitting the picture to the stand: turn it until the card is upright,
    /// then size the guide to the card. Both are remembered per camera.
    private var cameraSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Camera")
                    .font(.headline)
                Spacer()
                Text("Turned \(cameraSource.rotation.degrees)°")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                rotateButton
                    .labelStyle(.iconOnly)
            }
            LabeledContent("Guide size") {
                Slider(value: guideWidth, in: FrameGuide.widthRange) { isEditing in
                    if !isEditing {
                        Task { await cameraSource.rememberGuide() }
                    }
                }
                .accessibilityValue("\(Int((cameraSource.guide.widthFraction * 100).rounded())) percent of the frame")
            }
            .font(.footnote)
            Text("Fit the dashed outline to the card on the stand; photos are cropped to it.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
        .disabled(model.cameraState != .ready || model.isAutoScanning)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private var guideWidth: Binding<Double> {
        Binding(get: { cameraSource.guide.widthFraction }, set: { cameraSource.resizeGuide(to: $0) })
    }
    #endif

    // MARK: - Shared controls

    private var batchMenu: some View {
        Menu {
            Button {
                isStartingRun = true
            } label: {
                Label("Start run…", systemImage: "plus")
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.batch?.displayName ?? String(localized: "Batch"))
                        .lineLimit(1)
                    if let batch = model.batch {
                        Text(batchSubtitle(batch))
                            .font(.caption2)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: "tray.full")
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel("Batch \(model.batch?.displayName ?? ""), \(model.batch.map(batchSubtitle) ?? "")")
        .accessibilityHint("Opens batch options")
    }

    private var torchButton: some View {
        Button {
            Task { await model.toggleTorch() }
        } label: {
            Image(systemName: model.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                .font(.title3)
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .accessibilityLabel(model.isTorchOn ? "Turn torch off" : "Turn torch on")
    }

    /// Every way the camera can be missing, each with the one way out it has.
    @ViewBuilder
    private var cameraUnavailable: some View {
        switch model.cameraState {
        case .denied:
            ContentUnavailableView {
                Label("Camera access needed", systemImage: "camera")
            } description: {
                #if os(macOS)
                Text("Allow Riftbound Scanner under Privacy & Security › Camera in System Settings to scan cards.")
                #else
                Text("Allow camera access in Settings to scan cards.")
                #endif
            } actions: {
                Button(SystemSettingsPane.openButtonTitle) {
                    if let url = SystemSettingsPane.camera.url {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .noCamera:
            ContentUnavailableView {
                Label("No camera found", systemImage: "video.slash")
            } description: {
                #if os(macOS)
                Text("Put your iPhone on the feeder's stand, near this Mac and signed in to the same Apple Account with Wi‑Fi and Bluetooth on. It shows up here through Continuity Camera; a USB camera works too.")
                #else
                Text(CameraError.noCamera.message)
                #endif
            }
        case .disconnected(let name):
            ContentUnavailableView {
                Label("\(name) disconnected", systemImage: "iphone.slash")
            } description: {
                Text("Feeding has stopped. Scanning picks up again when it reconnects, or choose another camera.")
            } actions: {
                #if os(macOS)
                CameraPicker(source: cameraSource)
                    .fixedSize()
                #endif
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for \(name) to reconnect")
            }
        case .unavailable(let message):
            ContentUnavailableView {
                Label("Camera unavailable", systemImage: "camera.badge.ellipsis")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.start() } }
                    .buttonStyle(.borderedProminent)
            }
        case .unknown, .starting, .ready:
            EmptyView()
        }
    }

    // MARK: - Feeder

    /// One row for the feeder link: every `FeederState` and the running loop
    /// gets its own presentation, with the one action that makes sense there.
    @ViewBuilder
    private var feederStrip: some View {
        Group {
            switch model.feeder.state {
            case .idle:
                feederRow(systemImage: "tray.and.arrow.down", text: Text("No feeder")) {
                    Button("Connect") { model.connectFeeder() }
                        .accessibilityHint("Looks for the card feeder over Bluetooth")
                }
            case .scanning:
                feederRow(systemImage: "dot.radiowaves.left.and.right", text: Text("Looking for feeder…"), isWorking: true) {
                    Button("Cancel") { model.disconnectFeeder() }
                }
            case .connecting:
                feederRow(systemImage: "dot.radiowaves.left.and.right", text: Text("Connecting…"), isWorking: true) {
                    Button("Cancel") { model.disconnectFeeder() }
                }
            case .ready(let version):
                switch model.autoScan {
                case .running(let progress):
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: progressText(progress), isWorking: true) {
                        stopButton
                    }
                case .draining(let progress, _):
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: Text("Identifying \(progress.identified) of \(progress.fed)…"), isWorking: true) {
                        EmptyView()
                    }
                case .off, .ended:
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: feederReadyText(version: version)) {
                        Button("Feed and scan") { model.startAutoScan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canStartAutoScan)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityHint("Feeds, photographs and saves cards until the hopper is empty")
                    }
                }
            case .feeding:
                if case .running(let progress) = model.autoScan {
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: progressText(progress), isWorking: true) {
                        stopButton
                    }
                } else {
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: Text("Feeding…"), isWorking: true) {
                        EmptyView()
                    }
                }
            case .failed(let failure):
                feederRow(systemImage: "exclamationmark.triangle", text: Text(failure.message)) {
                    switch failure {
                    case .bluetoothUnauthorized:
                        Button(SystemSettingsPane.openButtonTitle) {
                            if let url = SystemSettingsPane.bluetooth.url {
                                openURL(url)
                            }
                        }
                    case .bluetoothUnsupported:
                        EmptyView()
                    case .bluetoothOff, .connectionFailed, .disconnected:
                        Button("Retry") { model.connectFeeder() }
                    }
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var stopButton: some View {
        Button("Stop", role: .destructive) { model.stopAutoScan() }
            .keyboardShortcut(".", modifiers: .command)
            .accessibilityHint("Stops feeding; photos already taken are still identified")
    }

    /// Purpose and product in a few words: "Collection · OGN box".
    private func batchSubtitle(_ batch: ScanBatch) -> String {
        let purpose = batch.purpose == .collection ? String(localized: "Collection") : String(localized: "Calibration")
        switch batch.product {
        case .sealedBox(let set): return String(localized: "\(purpose) · \(set.rawValue) box")
        case .loose: return String(localized: "\(purpose) · loose cards")
        case .other(let name): return "\(purpose) · \(name)"
        case nil: return purpose
        }
    }

    private func progressText(_ progress: ScannerModel.AutoScanProgress) -> Text {
        Text("Fed \(progress.fed) · Identified \(progress.identified)")
    }

    private func feederReadyText(version: String?) -> Text {
        if let version {
            Text("Feeder ready · v\(version)")
        } else {
            Text("Feeder ready")
        }
    }

    private func feederRow(systemImage: String, text: Text, isWorking: Bool = false, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            if isWorking {
                ProgressView()
                    .tint(.white)
                    #if os(macOS)
                    .controlSize(.small)
                    #endif
            } else {
                Image(systemName: systemImage)
            }
            text.lineLimit(2)
            Spacer(minLength: 8)
            action()
        }
        .accessibilityElement(children: .contain)
    }

    private var summaryLabel: some View {
        let summary = model.summary
        return VStack(alignment: .leading) {
            Text("\(summary.total) scanned")
            if let accuracy = summary.topOneAccuracy {
                Text("\(accuracy.formatted(.percent.precision(.fractionLength(0)))) correct")
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var shutterButton: some View {
        Button {
            Task { await model.capture() }
        } label: {
            ZStack {
                Circle().stroke(.white, lineWidth: 4)
                Circle().fill(.white).padding(6)
            }
            .frame(width: 76, height: 76)
            .contentShape(Circle())
        }
        #if os(macOS)
        .buttonStyle(.plain)
        #endif
        .disabled(model.isBusy || model.isAutoScanning || model.cameraState != .ready)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel("Take photo")
        .accessibilityHint("Identifies the card inside the frame")
        .help("Take photo (Space)")
    }

    @ViewBuilder
    private var processingOverlay: some View {
        switch model.phase {
        case .capturing:
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .overlay { ProgressView("Capturing…").tint(.white).foregroundStyle(.white) }
        case .recognizing(let photo):
            Image(decorative: photo, scale: 1)
                .resizable()
                #if os(macOS)
                .scaledToFit()
                #else
                .scaledToFill()
                #endif
                .ignoresSafeArea()
                .overlay(.black.opacity(0.45))
                .overlay { ProgressView("Identifying…").tint(.white).foregroundStyle(.white) }
                .accessibilityLabel("Identifying the card")
        case .idle, .reviewing, .failed:
            EmptyView()
        }
    }

    // MARK: - Bindings

    private var pendingScan: Binding<ScannerModel.PendingScan?> {
        Binding(
            get: { model.pendingScan },
            set: { if $0 == nil { model.retake() } }
        )
    }

    private var isShowingProblem: Binding<Bool> {
        Binding(get: { model.problem != nil }, set: { if !$0 { model.dismissProblem() } })
    }

    private var isShowingStorageProblem: Binding<Bool> {
        Binding(get: { model.storageProblem != nil }, set: { if !$0 { model.dismissStorageProblem() } })
    }
}
