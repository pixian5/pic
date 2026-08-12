import CoreGraphics

enum ImageDisplayGeometry {
    static func containScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return nil
        }

        return min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
    }

    static func coverScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat? {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else {
            return nil
        }

        return max(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
    }
}
