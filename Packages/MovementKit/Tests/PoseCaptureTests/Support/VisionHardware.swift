import Metal

enum VisionHardware {
    // Revision-2 body pose reports no available main-stage compute device on the hosted macOS VM.
    // Keep hardware integration cases enabled on real Macs; never replace the revision with another model.
    static let supportsBodyPose = MTLCreateSystemDefaultDevice() != nil
}
