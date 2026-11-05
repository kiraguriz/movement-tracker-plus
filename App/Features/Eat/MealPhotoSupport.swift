import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Makes the JPEG that is sent to Muse: at most 1280 px on the longest side, upright, without metadata. The original
/// is never kept.
nonisolated enum PhotoPreparer {
    static let maxDimension = 1280

    /// Nil when the data is not an image.
    @concurrent
    static func prepare(_ data: Data) async -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // applies the orientation, so none has to be sent
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

// MARK: - Camera

/// The system camera for one photo. This is the only UIKit in the meal photo flow: SwiftUI has no still-camera view.
struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    let onCancel: () -> Void

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (Data) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            Task {
                if let data = await Self.encode(image) {
                    onCapture(data)
                } else {
                    onCancel()
                }
            }
        }

        /// A full-size photo takes a while to encode, so it is done off the main thread.
        @concurrent
        private nonisolated static func encode(_ image: UIImage) async -> Data? {
            image.jpegData(compressionQuality: 0.9)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

// MARK: - Debug sample

#if DEBUG
/// A drawn plate of food for the Simulator, which has no camera. It is large on purpose so the downscale runs.
@MainActor
enum SamplePhoto {
    static func jpegData() -> Data? {
        let art = ZStack {
            Color(red: 0.55, green: 0.42, blue: 0.3)
            Circle().fill(.white).frame(width: 1300, height: 1300)
            Circle().stroke(Color(white: 0.85), lineWidth: 24).frame(width: 1000, height: 1000)
            Ellipse().fill(Color(red: 1, green: 0.85, blue: 0.2)).frame(width: 420, height: 340).offset(x: -150, y: -80)
            Ellipse().fill(Color(red: 0.95, green: 0.97, blue: 0.9)).frame(width: 560, height: 440).offset(x: -150, y: -80).zIndex(-1)
            RoundedRectangle(cornerRadius: 40).fill(Color(red: 0.8, green: 0.6, blue: 0.3)).frame(width: 360, height: 360).offset(x: 280, y: 160)
        }
        .frame(width: 2000, height: 1500)
        let renderer = ImageRenderer(content: art)
        renderer.scale = 1
        return renderer.uiImage?.jpegData(compressionQuality: 0.9)
    }
}
#endif
