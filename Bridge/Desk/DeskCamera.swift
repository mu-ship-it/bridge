import AVFoundation
import CoreImage
import CoreML
import UIKit
import Vision

/// The desk's front camera, for CamPresence only. Lowest preset, a couple of frames a second, and
/// a frame is analysed only when the detector asks for one. Each frame is looked at on the camera's
/// own queue with Apple Vision (face rectangles + upper-body rectangles) and the exposure the camera
/// chose, then dropped right there: no frame is kept, logged, written or sent. What comes out is a
/// `CamFrame`. Runs only while the desk is on screen on duty (DeskStation.runCamera).
///
/// Identity (FaceID): when the largest face is frontal, sharp and big enough, its five landmarks are
/// aligned onto a 112×112 crop in memory, `FaceEmbedder.mlmodel` turns that into an embedding, and
/// the crop is dropped with the frame. Only the embedding leaves this file.
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
    private let embedder = FaceEmbedding()

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
        // 640×480: enough pixels for a face across the desk to be recognised (FaceID.minFacePixels).
        session.sessionPreset = session.canSetSessionPreset(.vga640x480) ? .vga640x480 : .medium
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
        let people = bodies.results ?? []
        frame.hit = !found.isEmpty || !people.isEmpty
        frame.looking = found.contains { CamFrame.isLooking(yaw: $0.yaw?.doubleValue, pitch: $0.pitch?.doubleValue) }
        let largestFace = found.max { $0.boundingBox.width < $1.boundingBox.width }
        if let box = largestFace?.boundingBox ?? people.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox {
            frame.center = (Double(box.midX), Double(box.midY))
        }
        if let face = largestFace { frame.face = read(face, pixels: pixels) }
        return frame
    }

    /// The face's embedding when it is readable (FaceID.isReadable); nil otherwise.
    private func read(_ face: VNFaceObservation, pixels: CVPixelBuffer) -> FaceRead? {
        // .leftMirrored … .left turn the buffer a quarter: the upright image is as wide as the buffer is tall.
        let quarterTurn = orientation.rawValue >= CGImagePropertyOrientation.leftMirrored.rawValue
        let width = Double(quarterTurn ? CVPixelBufferGetHeight(pixels) : CVPixelBufferGetWidth(pixels))
        // Angles and size first (cheap); the capture quality is checked once it is measured below.
        guard FaceID.isReadable(yaw: face.yaw?.doubleValue, pitch: face.pitch?.doubleValue, quality: FaceID.minQuality,
                                widthPixels: Double(face.boundingBox.width) * width) else { return nil }
        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [face]
        let quality = VNDetectFaceCaptureQualityRequest()
        quality.inputFaceObservations = [face]
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([landmarks, quality])
        } catch {
            return nil
        }
        let score = (quality.results?.first?.faceCaptureQuality).map(Double.init)
        guard let score, score >= FaceID.minQuality, let marked = landmarks.results?.first,
              let embedding = embedder.embed(pixels, orientation: orientation, face: marked) else { return nil }
        return FaceRead(embedding: embedding, quality: score)
    }
}

/// SFace (MobileFaceNet) in Core ML: an aligned 112×112 RGB face -> a 128-d embedding. The crop
/// lives only inside `embed`.
final class FaceEmbedding: @unchecked Sendable {
    private lazy var model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: config)
    }()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var crop: CVPixelBuffer?

    func embed(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation, face: VNFaceObservation) -> [Float]? {
        guard let model, let points = Self.fivePoints(face) else { return nil }
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let size = image.extent.size
        let source = points.map { (x: Double($0.x * size.width), y: Double($0.y * size.height)) }
        guard let t = FaceAlign.transform(from: source, to: FaceAlign.referenceBottomLeft) else { return nil }
        let moved = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(a: t.a, b: t.b, c: -t.b, d: t.a, tx: t.tx, ty: t.ty))
            .cropped(to: CGRect(x: 0, y: 0, width: FaceAlign.size, height: FaceAlign.size))
        guard let out = buffer() else { return nil }
        context.render(moved, to: out, bounds: CGRect(x: 0, y: 0, width: FaceAlign.size, height: FaceAlign.size),
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        guard let result = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: out)])),
              let array = result.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        return (0..<array.count).map { array[$0].floatValue }
    }

    /// Eye, eye, nose, mouth corner, mouth corner — left to right in the image, normalised to the
    /// image (bottom-left origin), as FaceAlign.reference.
    static func fivePoints(_ face: VNFaceObservation) -> [CGPoint]? {
        guard let marks = face.landmarks, let left = marks.leftPupil ?? marks.leftEye, let right = marks.rightPupil ?? marks.rightEye,
              let nose = marks.nose, let lips = marks.outerLips else { return nil }
        let box = face.boundingBox
        func inImage(_ p: CGPoint) -> CGPoint { CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height) }
        func centre(_ r: VNFaceLandmarkRegion2D) -> CGPoint? {
            let ps = r.normalizedPoints
            guard !ps.isEmpty else { return nil }
            return inImage(CGPoint(x: ps.map(\.x).reduce(0, +) / CGFloat(ps.count), y: ps.map(\.y).reduce(0, +) / CGFloat(ps.count)))
        }
        guard let a = centre(left), let b = centre(right), let tip = centre(nose),
              let mouthL = lips.normalizedPoints.min(by: { $0.x < $1.x }).map(inImage),
              let mouthR = lips.normalizedPoints.max(by: { $0.x < $1.x }).map(inImage) else { return nil }
        let eyes = [a, b].sorted { $0.x < $1.x }
        return [eyes[0], eyes[1], tip, mouthL, mouthR]
    }

    private func buffer() -> CVPixelBuffer? {
        if let crop { return crop }
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        var made: CVPixelBuffer?
        CVPixelBufferCreate(nil, Int(FaceAlign.size), Int(FaceAlign.size), kCVPixelFormatType_32BGRA, attrs as CFDictionary, &made)
        crop = made
        return made
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
