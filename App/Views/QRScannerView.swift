import SwiftUI
import VisionKit
import Vision
import AVFoundation
import PhotosUI

/// Camera-based QR scanner using DataScannerViewController (iOS 16+).
/// Calls `onResult` with the first scanned string, then dismisses.
struct QRScannerView: UIViewControllerRepresentable {
    var onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(onResult: onResult, dismiss: dismiss) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onResult: (String) -> Void
        private let dismiss: DismissAction
        private var didReport = false

        init(onResult: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onResult = onResult
            self.dismiss  = dismiss
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !didReport else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let str = code.payloadStringValue {
                    didReport = true
                    dataScanner.stopScanning()
                    onResult(str)
                    dismiss()
                    return
                }
            }
        }
    }
}

/// Wrapper that checks device support and the camera permission before
/// presenting the scanner. A refusal gets a way to Settings instead of a
/// black view; a device without a usable camera is told to use a photo.
struct QRScannerSheet: View {
    var onResult: (String) -> Void
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        Group {
            if !DataScannerViewController.isSupported {
                unavailable
            } else {
                switch access {
                case .authorized:
                    // `isAvailable` is false under a parental restriction or
                    // while another app holds the camera.
                    if DataScannerViewController.isAvailable {
                        QRScannerView(onResult: onResult)
                            .ignoresSafeArea()
                    } else {
                        unavailable
                    }
                case .notDetermined:
                    ProgressView()
                        .task {
                            let granted = await AVCaptureDevice.requestAccess(for: .video)
                            access = granted ? .authorized : .denied
                        }
                case .denied, .restricted:
                    denied
                @unknown default:
                    denied
                }
            }
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            L10n.cameraUnavailableTitle.localized(),
            systemImage: "camera.slash",
            description: Text(L10n.cameraUnavailableBody.localized())
        )
    }

    private var denied: some View {
        ContentUnavailableView {
            Label(L10n.cameraDeniedTitle.localized(), systemImage: "camera.slash")
        } description: {
            Text(L10n.cameraDeniedBody.localized())
        } actions: {
            Button(L10n.openSettingsAction.localized()) {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - QR code from a picture

/// Reads the first QR code out of an image's bytes (a screenshot of a link,
/// a saved QR picture). Pure Vision, so it runs off the main actor.
enum QRImageDecoder {
    static func decode(_ data: Data) -> String? {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        let handler = VNImageRequestHandler(data: data, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        return request.results?.compactMap { $0.payloadStringValue }.first
    }
}

/// Presents the photo library and hands the decoded QR text to `onResult`,
/// or the reason to `onFailure`. Delivery waits for the picker to go away:
/// an alert raised while it is still animating out is lost under it.
struct PhotoQRPicker: ViewModifier {
    @Binding var isPresented: Bool
    let onResult: (String) -> Void
    let onFailure: (String) -> Void
    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection, matching: .images)
            .onChange(of: selection) { _, item in
                guard let item else { return }
                selection = nil
                Task {
                    let data = try? await item.loadTransferable(type: Data.self)
                    let text: String?
                    if let data {
                        text = await Task.detached { QRImageDecoder.decode(data) }.value
                    } else {
                        text = nil
                    }
                    try? await Task.sleep(for: .milliseconds(600))
                    if let text {
                        onResult(text)
                    } else {
                        onFailure(L10n.photoQRNotFound.localized())
                    }
                }
            }
    }
}

extension View {
    /// "Scan from photo": the library picker plus the QR decode, in one modifier.
    func photoQRImport(isPresented: Binding<Bool>,
                       onResult: @escaping (String) -> Void,
                       onFailure: @escaping (String) -> Void) -> some View {
        modifier(PhotoQRPicker(isPresented: isPresented, onResult: onResult, onFailure: onFailure))
    }
}
