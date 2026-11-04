import AVFoundation
import CoreImage
import CoreMedia
import CoreMotion
import KeyCore
import PhotosUI
import SwiftUI
import UIKit

/// Camera with live quality hints: card guide outline, level, brightness check.
struct CameraSheet: View {
    let onPhoto: (UIImage) -> Void

    @State private var controller = CameraController()
    @State private var pickedItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var focusDot: CGPoint?

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session, controller: controller)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let location = value.location
                            focusDot = location
                            controller.focusAt(layerPoint: location)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                                if focusDot == location { focusDot = nil }
                            }
                        }
                )

            liveOverlay

            if let focusDot {
                Crosshair()
                    .frame(width: 52, height: 52)
                    .foregroundStyle(.white)
                    .shadow(radius: 3)
                    .position(focusDot)
                    .allowsHitTesting(false)
                    .animation(.easeOut(duration: 0.25), value: focusDot)
            }

            GeometryReader { geo in
                let cardWidth = geo.size.width * 0.82
                let cardHeight = cardWidth / (85.60 / 53.98)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        style: StrokeStyle(lineWidth: 3, dash: [12, 8])
                    )
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: cardWidth, height: cardHeight)
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.44)
            }

            VStack {
                HStack(spacing: 10) {
                        Spacer()
                        if controller.torchAvailable {
                            Button {
                                controller.toggleTorch()
                            } label: {
                                Image(systemName: controller.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                                    .font(.title3)
                                    .foregroundStyle(controller.isTorchOn ? .yellow : .white)
                                    .frame(width: 44, height: 44)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                            .accessibilityLabel(controller.isTorchOn ? "Turn flashlight off" : "Turn flashlight on")
                        }
                        Button {
                            controller.liveHintsEnabled.toggle()
                        } label: {
                            Image(systemName: "viewfinder")
                                .font(.title3)
                                .foregroundStyle(controller.liveHintsEnabled ? .green : .gray)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.45), in: Circle())
                        }
                        .accessibilityLabel("Live key finder \(controller.liveHintsEnabled ? "on" : "off")")
                }
                .padding(.trailing, 6)
                .padding(.top, 8)
                Spacer()
                Text("Hold the phone UPRIGHT (portrait). Key flat inside the dashed outline, brand side up and readable, BOW (handle) to the LEFT. Ring can stay on; the bow may hang off the card as long as the cut row sits on it.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(8)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                controls
            }
            .padding()

            if let error = controller.lastError {
                Text(error)
                    .padding()
                    .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .task {
            controller.onCapture = onPhoto
            controller.start()
        }
        .onDisappear { controller.stop() }
        .photosPicker(isPresented: $showPicker, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    onPhoto(image)
                }
                pickedItem = nil
            }
        }
    }

    /// Real-time detection: card quad (dashed green) + where the KEY lives
    /// (solid green box). Cosmetic only — capture never waits on it.
    private var liveOverlay: some View {
        GeometryReader { _ in
            ZStack(alignment: .topLeading) {
                if controller.liveHintsEnabled, let quad = controller.liveCardQuad, quad.count == 4 {
                    Path { path in
                        path.move(to: quad[0])
                        for pt in quad.dropFirst() { path.addLine(to: pt) }
                        path.closeSubpath()
                    }
                    .stroke(Color.green.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                }
                if controller.liveHintsEnabled, let key = controller.liveKeyRect,
                   key.width > 6, key.height > 6 {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.green, lineWidth: 3)
                        .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .top) {
                            Text("KEY")
                                .font(.caption2.weight(.bold))
                                .padding(3)
                                .background(.black.opacity(0.55), in: Capsule())
                                .offset(y: -22)
                        }
                        .frame(width: key.width, height: key.height)
                        .position(x: key.midX, y: key.midY)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack {
            Button {
                showPicker = true
            } label: {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .frame(width: 56, height: 56)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .accessibilityLabel("Choose a photo from the library")
            Spacer()
            Button {
                controller.capture()
            } label: {
                Circle()
                    .stroke(.white, lineWidth: 4)
                    .frame(width: 74, height: 74)
                    .overlay(Circle().fill(.white).padding(6))
            }
            .accessibilityLabel("Capture photo of the key")
            Spacer()
            Color.clear.frame(width: 56, height: 56)
        }
    }
}

/// AVCaptureSession plumbing + motion/brightness hints.
@Observable
final class CameraController: NSObject {
    let session = AVCaptureSession()

    var onCapture: ((UIImage) -> Void)?
    var lastError: String?
    var brightness = 128.0
    var rollDegrees = 0.0
    var tiltDegrees = 0.0

    // Camera controls (Spec): flashlight, tap-to-focus, live key finder.
    var torchAvailable = false
    var isTorchOn = false
    var liveHintsEnabled = true
    /// Live detection results in PREVIEW-LAYER view space (full-screen incl.
    /// safe areas — overlay views must ignoreSafeArea to share this space).
    var liveCardQuad: [CGPoint]?
    var liveKeyRect: CGRect?

    @ObservationIgnored fileprivate weak var previewLayer: AVCaptureVideoPreviewLayer?
    @ObservationIgnored private var captureDevice: AVCaptureDevice?
    @ObservationIgnored private var focusSeq = 0
    @ObservationIgnored private var frameIndex = 0
    @ObservationIgnored private var liveInFlight = false
    @ObservationIgnored private var liveMissStreak = 0

    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sampleQueue = DispatchQueue(label: "keydecoder.camera.samples")
    // Serial queue owns every session state transition; re-entry (Retake ->
    // fresh CameraSheet) must never interleave start/stop/capture.
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "keydecoder.camera.session")
    @ObservationIgnored private let motion = CMMotionManager()
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var lastBrightnessPublish = Date.distantPast

    func start() {
        if !configured { configureSession() }
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(
                using: .xArbitraryZVertical,
                to: .main
            ) { [weak self] data, _ in
                guard let self, let data else { return }
                let g = data.gravity
                self.tiltDegrees = acos(min(1, abs(g.z))) * 180 / .pi
                self.rollDegrees = atan2(g.x, -g.y) * 180 / .pi
            }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
        motion.stopDeviceMotionUpdates()
    }

    func capture() {
        // ALWAYS portrait (Spec): the whole capture UI, the card guide and the
        // analysis assume an upright grip. Gravity-derived angles occasionally
        // produced sideways photos from a canted hold — "rotates the picture
        // inexplicably". Deterministic beats adaptive here.
        sessionQueue.async { [session, photoOutput] in
            guard session.isRunning,
                  let connection = photoOutput.connection(with: .video),
                  connection.isActive,
                  connection.isVideoRotationAngleSupported(90)
            else {
                DispatchQueue.main.async { self.lastError = "Camera warming up — try again in a moment" }
                return
            }
            connection.videoRotationAngle = 90
            photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
    }

    func toggleTorch() {
        let on = !isTorchOn
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice, device.hasTorch else { return }
            do { try device.lockForConfiguration() } catch { return }
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.isTorchOn = on }
        }
    }

    /// Tap-to-focus (Spec): one-shot AF at the tapped point + metering there,
    /// then back to continuous AF after a few seconds so moving the phone
    /// still refocuses.
    func focusAt(layerPoint: CGPoint) {
        guard let layer = previewLayer else { return }
        let point = layer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        focusSeq += 1
        let seq = focusSeq
        sessionQueue.async { [weak self] in
            guard let self, let device = self.captureDevice else { return }
            do { try device.lockForConfiguration() } catch { return }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            device.unlockForConfiguration()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.focusSeq == seq, let device = self.captureDevice else { return }
                do { try device.lockForConfiguration() } catch { return }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                device.unlockForConfiguration()
            }
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        // Modern discovery API (AVCaptureDevice.default(_:for:position:) is deprecated).
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualWideCamera],
            mediaType: .video,
            position: .back
        )
        if let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discovery.devices.first,
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            captureDevice = device
            torchAvailable = device.hasTorch
        }
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.videoSettings = [
            String(kCVPixelBufferPixelFormatTypeKey): Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: sampleQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        configured = true
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: (any Error)?
    ) {
        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async { self.lastError = "Capture failed — try again." }
            return
        }
        DispatchQueue.main.async { self.onCapture?(image) }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func videoOutput(
        _ output: AVCaptureVideoDataOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return }
        let base = raw.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var sum = 0
        var count = 0
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                sum += Int(base[y * stride + x])
                count += 1
                x += 16
            }
            y += 16
        }
        guard count > 0 else { return }
        let average = Double(sum) / Double(count)
        // Throttle UI churn.
        let now = Date()
        if now.timeIntervalSince(lastBrightnessPublish) > 0.4 {
            lastBrightnessPublish = now
            DispatchQueue.main.async { self.brightness = average }
        }
        pumpLiveDetection(sampleBuffer)
    }

    // MARK: - Live key finder (cosmetic; capture never waits on it)

    private func pumpLiveDetection(_ sampleBuffer: CMSampleBuffer) {
        frameIndex += 1
        guard liveHintsEnabled, !liveInFlight, frameIndex % 5 == 0 else { return }
        liveInFlight = true
        // CMSampleBuffer is a bridged CF type — ARC keeps it alive for the
        // closure; the C retain/release macros are not imported into Swift.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hit = Self.detectLive(sampleBuffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.apply(hit: hit)
                self.liveInFlight = false
            }
        }
    }

    private func apply(hit: LiveHit?) {
        guard let hit else {
            // Hysteresis: hold the last overlay for a few misses — Vision
            // blinks, the user shouldn't see a strobe.
            liveMissStreak += 1
            if liveMissStreak >= 3 { liveCardQuad = nil; liveKeyRect = nil }
            return
        }
        guard let layer = previewLayer else { return }
        liveMissStreak = 0
        liveCardQuad = hit.quadNorm.map { layer.layerPointConverted(fromCaptureDevicePoint: $0) }
        liveKeyRect = layer.layerRectConverted(fromMetadataOutputRect: hit.keyRectNorm)
    }

    fileprivate struct LiveHit {
        let quadNorm: [CGPoint]     // card quad, normalized unrotated frame space
        let keyRectNorm: CGRect     // key bounding box, same space
    }

    fileprivate static func detectLive(_ sampleBuffer: CMSampleBuffer) -> LiveHit? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard ci.extent.width > 0 else { return nil }
        let scale = 400.0 / ci.extent.width
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = ciContext.createCGImage(small, from: small.extent) else { return nil }
        guard let card = CardDetector.detect(in: cg), card.confident,
              let gray = GrayImage(cgImage: cg) else { return nil }

        // Warp to the same normalized card view the decoder uses, then run
        // the real segmentation — the overlay shows what the app WOULD read.
        let wC = 700
        let hC = Perspective.outputHeight(forWidth: wC)
        let marginFrac = 0.16
        let sourceQuad = Perspective.expandedQuad(card.quad, marginFrac: marginFrac) ?? card.quad
        guard let warped = Perspective.warpGray(
            gray, quad: sourceQuad, outputWidth: wC, outputHeight: hC
        ), let scene = MeasurementPipeline.analyzeScene(
            corrected: warped.image,
            pixelsPerMm: Perspective.pixelsPerMm(forWidth: wC, marginFrac: marginFrac),
            marginFrac: marginFrac
        ) else { return nil }

        let m = scene.mask
        guard m.mask.count == m.width * m.height else { return nil }
        var minX = m.width, minY = m.height, maxX = -1, maxY = -1
        for row in 0..<m.height {
            let base = row * m.width
            for col in 0..<m.width where m.mask[base + col] {
                if col < minX { minX = col }
                if col > maxX { maxX = col }
                if row < minY { minY = row }
                if row > maxY { maxY = row }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let keyRectC = CGRect(
            x: CGFloat(minX) - 10, y: CGFloat(minY) - 10,
            width: CGFloat(maxX - minX) + 20, height: CGFloat(maxY - minY) + 20
        )
        // Corrected view -> camera frame: warpGray hands us the frame->corrected
        // homography; its inverse maps the key box back out.
        let inv = warped.transform.inverted()
        let cornersC = [
            keyRectC.origin,
            CGPoint(x: keyRectC.maxX, y: keyRectC.minY),
            CGPoint(x: keyRectC.maxX, y: keyRectC.maxY),
            CGPoint(x: keyRectC.minX, y: keyRectC.maxY),
        ]
        let cornersFrame = cornersC.map { inv?.apply($0) ?? .zero }
        guard inv != nil, let first = cornersFrame.first else { return nil }
        var rect = CGRect(origin: first, size: .zero)
        for p in cornersFrame.dropFirst() { rect = rect.union(CGRect(origin: p, size: .zero)) }

        let fw = CGFloat(cg.width), fh = CGFloat(cg.height)
        let quadNorm = card.quad.map { CGPoint(x: $0.x / fw, y: $0.y / fh) }
        let keyNorm = CGRect(
            x: rect.minX / fw, y: rect.minY / fh,
            width: rect.width / fw, height: rect.height / fh
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard keyNorm.width > 0.005, keyNorm.height > 0.005, keyNorm.width < 0.95 else { return nil }
        return LiveHit(quadNorm: quadNorm, keyRectNorm: keyNorm)
    }

    @ObservationIgnored nonisolated(unsafe) fileprivate static let ciContext = CIContext()
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let controller: CameraController

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        controller.previewLayer = view.previewLayer
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        controller.previewLayer = uiView.previewLayer
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// Tap-to-focus reticle: square bracket + crosshair, camera-UI style.
struct Crosshair: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let inset = rect.width * 0.18
        p.addRect(rect.insetBy(dx: inset, dy: inset))
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        p.move(to: CGPoint(x: mid.x - 6, y: mid.y)); p.addLine(to: CGPoint(x: mid.x + 6, y: mid.y))
        p.move(to: CGPoint(x: mid.x, y: mid.y - 6)); p.addLine(to: CGPoint(x: mid.x, y: mid.y + 6))
        return p
    }
}
