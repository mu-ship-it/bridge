import AVFoundation
import UIKit

/// Parsed `camera.capture` params: `facing` (`back` default, `front`), `max_px` (64–4096, default
/// 1024; longest edge), `timeout` (5–110 s, default 90).
struct CameraCaptureParams: Sendable, Equatable {
    let front: Bool
    let maxPx: Int
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        front = try Params.choice(p, "facing", ["back", "front"]) == "front"
        maxPx = try Params.int(p, "max_px", in: 64...4096) ?? 1024
        timeout = try Presenter.timeout(p)
    }
}

/// `camera.capture` → opens the camera on screen; Mu takes the photo.
/// Result: `{jpeg_base64, width, height}`. Mu cancelling is `ok:false`, code `cancelled`.
struct CameraCaptureCapability: Capability {
    let name = "camera.capture"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try CameraCaptureParams(job.params)
        guard await UIImagePickerController.isSourceTypeAvailable(.camera) else {
            throw CapabilityError.unavailable("No camera on this device (simulator?)")
        }
        try CameraAccess.require()
        let image: UIImage = try await Presenter.present(timeout: q.timeout) { session in
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.cameraCaptureMode = .photo
            if q.front, UIImagePickerController.isCameraDeviceAvailable(.front) { picker.cameraDevice = .front }
            let delegate = PickerDelegate(session)
            picker.delegate = delegate
            session.keepAlive = delegate
            return picker
        }
        guard let jpeg = await ImageJPEG.encode(image, maxPx: q.maxPx) else {
            throw CapabilityError(code: "failed", message: "Could not encode the photo")
        }
        return .object([
            "jpeg_base64": .string(jpeg.data.base64EncodedString()),
            "width": .number(Double(jpeg.size.width)),
            "height": .number(Double(jpeg.size.height)),
        ])
    }

    @MainActor
    private final class PickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let session: PresentedSession<UIImage>
        init(_ session: PresentedSession<UIImage>) { self.session = session }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                session.succeed(image)
            } else {
                session.fail(CapabilityError(code: "failed", message: "The camera returned no image"))
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            session.fail(CapabilityError.cancelled)
        }
    }
}

/// Camera permission, shared by `camera.capture` and `barcode.scan`.
enum CameraAccess {
    static var state: String { PermissionState.describe(AVCaptureDevice.authorizationStatus(for: .video)) }

    static func require() throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined: throw CapabilityError.permissionMissing("Camera")
        default: throw CapabilityError.permissionDenied("Camera")
        }
    }

    @discardableResult
    static func requestAuthorization() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

/// Downscale (never upscale) and JPEG-encode, orientation baked in.
enum ImageJPEG {
    static func encode(_ image: UIImage, maxPx: Int, quality: CGFloat = 0.8) async -> (data: Data, size: CGSize)? {
        await MainActor.run {
            let pixel = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
            let target = PhotosRecentParams.fitted(pixel, maxPx: maxPx)
            guard target != .zero else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
            return scaled.jpegData(compressionQuality: quality).map { ($0, target) }
        }
    }
}
