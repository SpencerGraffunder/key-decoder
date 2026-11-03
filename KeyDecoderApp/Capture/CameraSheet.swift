import AVFoundation
import CoreMedia
import CoreMotion
import PhotosUI
import SwiftUI
import UIKit

/// Camera with live quality hints: card guide outline, level, brightness check.
struct CameraSheet: View {
    let onPhoto: (UIImage) -> Void

    @State private var controller = CameraController()
    @State private var pickedItem: PhotosPickerItem?
    @State private var showPicker = false

    var body: some View {
        ZStack {
            CameraPreview(session: controller.session)
                .ignoresSafeArea()

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
                qualityBadge
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

    private var qualityBadge: some View {
        let (text, color) = controller.qualityHint
        return Text(text)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.9), in: Capsule())
            .foregroundStyle(.white)
            .accessibilityLabel("Capture quality: \(text)")
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

    var qualityHint: (String, Color) {
        if brightness < 60 { return ("Too dark — add light", .orange) }
        if brightness > 225 { return ("Too bright — reduce glare", .orange) }
        if tiltDegrees > 35 { return ("Too tilted — hold the phone flat over the card", .orange) }
        if abs(rollDegrees) > 15 { return ("Hold the phone upright (portrait)", .yellow) }
        return ("Good — hold steady, then capture", .green)
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
        guard now.timeIntervalSince(lastBrightnessPublish) > 0.4 else { return }
        lastBrightnessPublish = now
        DispatchQueue.main.async { self.brightness = average }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
