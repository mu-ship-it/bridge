import Foundation
@preconcurrency import Photos
import UIKit

/// Parsed `photos.recent` params: `count` (1–10, default 3), `max_px` (64–2048, default 512; longest edge).
struct PhotosRecentParams: Sendable, Equatable {
    let count: Int
    let maxPx: Int

    init(_ params: [String: JSONValue]?) throws {
        let p = params ?? [:]
        count = try Params.int(p, "count", in: 1...10) ?? 3
        maxPx = try Params.int(p, "max_px", in: 64...2048) ?? 512
    }

    /// Size that fits `pixel` inside `maxPx` on its longest edge (never upscales).
    static func fitted(_ pixel: CGSize, maxPx: Int) -> CGSize {
        let longest = max(pixel.width, pixel.height)
        guard longest > 0 else { return .zero }
        let scale = min(1, CGFloat(maxPx) / longest)
        return CGSize(width: max(1, (pixel.width * scale).rounded()), height: max(1, (pixel.height * scale).rounded()))
    }
}

/// `photos.recent` → `{count, photos: [{id, created, lat?, lon?, width, height, jpeg_base64}]}`.
/// Images are always downscaled to `max_px`; full-resolution data never leaves the phone.
struct PhotosRecentCapability: Capability {
    let name = "photos.recent"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try PhotosRecentParams(job.params)
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: break
        case .notDetermined: throw CapabilityError.permissionMissing("Photos")
        default: throw CapabilityError.permissionDenied("Photos")
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = q.count
        let fetched = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        var photos: [JSONValue] = []
        for asset in assets {
            try Task.checkCancellation()
            guard let jpeg = await Self.jpeg(asset, maxPx: q.maxPx) else { continue }
            var o: [String: JSONValue] = [
                "id": .string(asset.localIdentifier),
                "created": asset.creationDate.map { .string(ISO.string($0)) } ?? .null,
                "width": .number(Double(jpeg.size.width)),
                "height": .number(Double(jpeg.size.height)),
                "jpeg_base64": .string(jpeg.data.base64EncodedString()),
            ]
            if let loc = asset.location {
                o["lat"] = .number(loc.coordinate.latitude)
                o["lon"] = .number(loc.coordinate.longitude)
            }
            photos.append(.object(o))
        }
        if assets.isEmpty == false, photos.isEmpty {
            throw CapabilityError.unavailable("Could not load any photo (iCloud-only originals?)")
        }
        return .object(["count": .number(Double(photos.count)), "photos": .array(photos)])
    }

    private static func jpeg(_ asset: PHAsset, maxPx: Int) async -> (data: Data, size: CGSize)? {
        let target = PhotosRecentParams.fitted(CGSize(width: asset.pixelWidth, height: asset.pixelHeight), maxPx: maxPx)
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { cont in
            PHImageManager.default().requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
                guard let image else { return cont.resume(returning: nil) }
                // Redraw at exactly `target` pixels so the output can never exceed max_px.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let size = PhotosRecentParams.fitted(CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale), maxPx: maxPx)
                let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                guard let data = rendered.jpegData(compressionQuality: 0.7) else { return cont.resume(returning: nil) }
                cont.resume(returning: (data, size))
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }
}
