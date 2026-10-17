import UIKit
import VisionKit

/// Parsed `barcode.scan` params: `timeout` (5–110 s, default 90).
struct BarcodeScanParams: Sendable, Equatable {
    let timeout: Int

    init(_ params: [String: JSONValue]?) throws {
        timeout = try Presenter.timeout(params ?? [:])
    }
}

/// `barcode.scan` → opens a live camera scanner on screen; returns the first code Mu points it at:
/// `{payload, symbology}` (QR, EAN, Code 128, PDF417, Aztec, …). Cancel is `ok:false`, code `cancelled`.
struct BarcodeScanCapability: Capability {
    let name = "barcode.scan"

    func run(_ job: Job) async throws -> JSONValue {
        let q = try BarcodeScanParams(job.params)
        guard await DataScannerViewController.isSupported else {
            throw CapabilityError.unavailable("Live scanning is not supported on this device (simulator, or pre-A12 chip)")
        }
        try CameraAccess.require()
        guard await DataScannerViewController.isAvailable else {
            throw CapabilityError.unavailable("The scanner is unavailable right now (camera in use or restricted)")
        }
        let code: [String: String] = try await Presenter.present(timeout: q.timeout) { session in
            let scanner = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                                    isHighlightingEnabled: true)
            let delegate = ScanDelegate(session)
            scanner.delegate = delegate
            scanner.navigationItem.title = "白手套 · Scan a code"
            scanner.navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .cancel, primaryAction: UIAction { _ in session.fail(CapabilityError.cancelled) })
            session.keepAlive = delegate
            session.onPresented = {
                do { try scanner.startScanning() } catch {
                    session.fail(CapabilityError.unavailable("Scanner did not start: \(error.localizedDescription)"))
                }
            }
            let nav = UINavigationController(rootViewController: scanner)
            nav.modalPresentationStyle = .fullScreen
            return nav
        }
        return .object(["payload": .string(code["payload"] ?? ""), "symbology": .string(code["symbology"] ?? "")])
    }

    @MainActor
    private final class ScanDelegate: NSObject, DataScannerViewControllerDelegate {
        let session: PresentedSession<[String: String]>
        init(_ session: PresentedSession<[String: String]>) { self.session = session }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
                dataScanner.stopScanning()
                session.succeed(["payload": payload, "symbology": Self.symbology(barcode.observation.symbology.rawValue)])
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            session.fail(CapabilityError.unavailable("Scanner became unavailable: \(error)"))
        }

        /// `VNBarcodeSymbologyQR` → `qr`.
        static func symbology(_ raw: String) -> String {
            raw.replacingOccurrences(of: "VNBarcodeSymbology", with: "").lowercased()
        }
    }
}
