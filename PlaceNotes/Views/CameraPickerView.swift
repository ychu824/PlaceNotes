import SwiftUI
import UIKit
import CoreLocation
import AVFoundation

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
            // UIImagePickerController does not expose CLLocation directly for camera source.
            // Location will be resolved post-save via PHAsset.location.
            parent.onCaptured(image, nil)
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
