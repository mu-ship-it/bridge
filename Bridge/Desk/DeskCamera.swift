import AVFoundation
import UIKit
import Vision

/// The desk's front camera, for CamPresence only. Lowest preset, a couple of frames a second, and
/// a frame is analysed only when the detector asks for one. Each frame is looked at on the camera's
/// own queue with Apple Vision (face rectangles + upper-body rectangles) and the exposure the camera
/// chose, then dropped right there: no frame is kept, logged, written or sent. What comes out is a
/// `CamFrame`. Runs only while the desk is on screen on duty (DeskStation.runCamera).
final class DeskCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Frames per second the camera delivers (clamped to what its format allows); most are dropped unseen.
    static let fps = 2.0

    private let session = AVCaptureSession()
    /// Everything below is touched only on this queue.
    private let queue = DispatchQueue(label: "desk.camera", qos: .utility)
    private var device: AVCaptureDevice?
    private var configured = false
    private var pending: CheckedContinuation<CamFrame?, Never>?
    private var request = 0
    private var orientation = CGImagePropertyOrientation.leftMirrored

    /// Camera allowed: asks once when it was never asked; denied or restricted is false.
    static func authorize() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .video)
        default: false
        }
    }

    /// Configures on first use and starts the session; false when there is no front camera or it cannot be opened.
    func start() async -> Bool {
        await withCheckedContinuation { done in
            queue.async {
                do {
                    try self.configure()
                    if !self.session.isRunning { self.session.startRunning() }
                    done.resume(returning: self.session.isRunning)
                } catch {
                    done.resume(returning: false)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { done in
            queue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.pending?.resume(returning: nil)
                self.pending = nil
                done.resume()
            }
        }
    }

    /// The next frame, analysed; nil when none arrives within `timeout` (interrupted, taken by another app).
    func frame(orientation: CGImagePropertyOrientation, timeout: TimeInterval) async -> CamFrame? {
        await withCheckedContinuation { (done: CheckedContinuation<CamFrame?, Never>) in
            queue.async {
                self.pending?.resume(returning: nil)
                self.request += 1
                let token = self.request
                self.pending = done
                self.orientation = orientation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    guard self.request == token, let late = self.pending else { return }
                    self.pending = nil
                    late.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Camera queue

    private func configure() throws {
        guard !configured else { return }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw CocoaError(.featureUnsupported)
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = session.canSetSessionPreset(.low) ? .low : .medium
        guard session.canAddInput(input), session.canAddOutput(output) else { throw CocoaError(.featureUnsupported) }
        session.addInput(input)
        session.addOutput(output)
        if let range = camera.activeFormat.videoSupportedFrameRateRanges.first, (try? camera.lockForConfiguration()) != nil {
            let fps = min(max(Self.fps, range.minFrameRate), range.maxFrameRate)
            let duration = CMTime(seconds: 1 / fps, preferredTimescale: 600)
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
        }
        device = camera
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let waiting = pending else { return }
        pending = nil
        waiting.resume(returning: analyse(sampleBuffer))
    }

    private func analyse(_ buffer: CMSampleBuffer) -> CamFrame {
        var frame = CamFrame(hit: false)
        if let device {
            frame.light = CamFrame.ev100(iso: Double(device.iso), seconds: device.exposureDuration.seconds,
                                         aperture: Double(device.lensAperture))
            frame.dark = CamFrame.isDark(ev100: frame.light, targetOffset: Double(device.exposureTargetOffset))
        }
        guard !frame.dark, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return frame }
        let faces = VNDetectFaceRectanglesRequest()
        faces.revision = VNDetectFaceRectanglesRequestRevision3   // yaw and pitch
        let bodies = VNDetectHumanRectanglesRequest()
        bodies.upperBodyOnly = true
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([faces, bodies])
        } catch {
            return frame
        }
        let found = faces.results ?? []
        frame.hit = !found.isEmpty || !(bodies.results ?? []).isEmpty
        frame.looking = found.contains { CamFrame.isLooking(yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue) }
        return frame
    }
}

extension DeskCamera {
    /// How Vision should read a front-camera buffer for the way the screen is turned (mirrored).
    @MainActor static var orientation: CGImagePropertyOrientation {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return switch scene?.effectiveGeometry.interfaceOrientation ?? .portrait {
        case .portraitUpsideDown: .rightMirrored
        case .landscapeLeft: .upMirrored
        case .landscapeRight: .downMirrored
        default: .leftMirrored
        }
    }
}
