import AVFoundation
import SwiftUI
import UIKit

struct ScannerView: View {
    let model: ScannerModel
    let session: AVCaptureSession
    let directory: CardDirectory

    @Environment(\.openURL) private var openURL
    @State private var isNamingBatch = false
    @State private var newBatchLabel = ""
    @State private var previewFrame: CGRect = .zero
    @State private var guideFrame: CGRect = .zero

    var body: some View {
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
        .alert("New batch", isPresented: $isNamingBatch) {
            TextField("Label, e.g. desk lamp", text: $newBatchLabel)
            Button("Start") {
                let label = newBatchLabel
                newBatchLabel = ""
                Task { await model.beginNewBatch(label: label) }
            }
            Button("Cancel", role: .cancel) { newBatchLabel = "" }
        } message: {
            Text("Batches group scans so different lighting or setups can be compared.")
        }
        .sensoryFeedback(.success, trigger: model.savedVerdictCount)
    }

    // MARK: - Layers

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
        case .denied:
            ContentUnavailableView {
                Label("Camera access needed", systemImage: "camera")
            } description: {
                Text("Allow camera access in Settings to scan cards.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        case .unavailable(let message):
            ContentUnavailableView("Camera unavailable", systemImage: "camera.badge.ellipsis", description: Text(message))
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Menu {
                    Button {
                        isNamingBatch = true
                    } label: {
                        Label("New batch…", systemImage: "plus")
                    }
                } label: {
                    Label(model.batch?.displayName ?? String(localized: "Batch"), systemImage: "tray.full")
                        .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityLabel("Batch \(model.batch?.displayName ?? "")")
                .accessibilityHint("Opens batch options")

                Spacer()

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
            .padding()

            feederStrip
                .padding(.horizontal)

            Spacer()

            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
                .aspectRatio(63.0 / 88.0, contentMode: .fit)
                .padding(.horizontal, 48)
                .accessibilityHidden(true)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { guideFrame = $0 }

            Spacer()

            if case .ended(let progress, let reason) = model.autoScan {
                autoScanResult(progress: progress, reason: reason)
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
                        Button("Stop", role: .destructive) { model.stopAutoScan() }
                            .accessibilityHint("Stops feeding; photos already taken are still identified")
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
                            .accessibilityHint("Feeds, photographs and saves cards until the hopper is empty")
                    }
                }
            case .feeding:
                if case .running(let progress) = model.autoScan {
                    feederRow(systemImage: "tray.and.arrow.down.fill", text: progressText(progress), isWorking: true) {
                        Button("Stop", role: .destructive) { model.stopAutoScan() }
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
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
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
                ProgressView().tint(.white)
            } else {
                Image(systemName: systemImage)
            }
            text.lineLimit(2)
            Spacer(minLength: 8)
            action()
        }
        .accessibilityElement(children: .contain)
    }

    private func autoScanResult(progress: ScannerModel.AutoScanProgress, reason: ScannerModel.AutoScanEnd) -> some View {
        HStack(spacing: 10) {
            Image(systemName: reason == .hopperEmpty ? "tray" : "info.circle")
            VStack(alignment: .leading, spacing: 2) {
                Text("\(progress.fed) fed, \(progress.identified) identified and saved")
                Text(reason.message)
            }
            .lineLimit(2)
            Spacer(minLength: 8)
            Button("Done") { model.dismissAutoScanResult() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Done") { model.dismissAutoScanResult() }
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
        }
        .disabled(model.isBusy || model.isAutoScanning)
        .accessibilityLabel("Take photo")
        .accessibilityHint("Identifies the card inside the frame")
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
                .scaledToFill()
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
