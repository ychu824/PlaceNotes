import SwiftUI
import UIKit
import CoreLocation
import AVFoundation
import ImageIO

struct CameraPickerView: UIViewControllerRepresentable {
    let onCaptured: (UIImage, CLLocation?) -> Void
    let onCancelled: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPickerView
        init(parent: CameraPickerView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                parent.onCancelled()
                return
            }
            let exif = Self.extractGPSLocation(from: info[.mediaMetadata] as? [String: Any])
            parent.onCaptured(image, exif)
        }

        private static func extractGPSLocation(from metadata: [String: Any]?) -> CLLocation? {
            guard let gps = metadata?[kCGImagePropertyGPSDictionary as String] as? [String: Any],
                  let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double,
                  let latRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
                  let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double,
                  let lonRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String else {
                return nil
            }
            let signedLat = latRef == "S" ? -lat : lat
            let signedLon = lonRef == "W" ? -lon : lon
            let altitude = (gps[kCGImagePropertyGPSAltitude as String] as? Double) ?? 0
            let hAcc = (gps[kCGImagePropertyGPSHPositioningError as String] as? Double) ?? 10
            return CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: signedLat, longitude: signedLon),
                altitude: altitude,
                horizontalAccuracy: hAcc,
                verticalAccuracy: -1,
                timestamp: Date()
            )
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancelled()
        }
    }

    /// Call before presenting — returns true if camera permission is granted.
    static func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
