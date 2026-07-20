import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers
import ImageIO

// MARK: - ImageManager
/// Central model that owns the list of images in the current folder and the current index.
/// All mutations happen on the @MainActor.

@MainActor
final class ImageManager: ObservableObject {

    struct ImageDetails {
        let name: String
        let path: String
        let dimensionsText: String
        let fileSizeText: String
        let formatText: String
        let modifiedText: String
        let indexText: String
        let cameraModel: String?
        let focalLength: String?
        let aperture: String?
        let iso: String?
        let gpsCoords: String?
    }

    // MARK: Published state
    @Published var images:        [URL]     = []
    @Published var currentIndex:  Int       = 0
    @Published var currentImage:  NSImage?  = nil
    @Published var isLoading:     Bool      = false
    @Published var folderURL:     URL?      = nil
    @Published var folderAuthorized: Bool   = true
    @Published var hasChanges:    Bool      = false
    @Published var hasHomeFolderAccess: Bool = true

    // MARK: Constants
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "webp", "gif",
        "bmp", "tiff", "tif", "heic", "heif"
    ]
    static let launchServicesDomain = "com.apple.LaunchServices/com.apple.launchservices.secure"
    // MARK: Computed helpers
    var hasImages:    Bool   { !images.isEmpty }
    var totalCount:   Int    { images.count }
    var displayIndex: Int    { currentIndex + 1 }
    var currentURL:   URL?   {
        guard hasImages, currentIndex < images.count else { return nil }
        return images[currentIndex]
    }
    var currentImageDetails: ImageDetails? {
        guard let url = currentURL else { return nil }

        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short

        let meta = fetchMetadata(for: url)

        return ImageDetails(
            name: url.lastPathComponent,
            path: url.path,
            dimensionsText: imageDimensionsText(for: currentImage),
            fileSizeText: values?.fileSize.map { formatter.string(fromByteCount: Int64($0)) } ?? "Unknown",
            formatText: url.pathExtension.uppercased(),
            modifiedText: values?.contentModificationDate.map(dateFormatter.string(from:)) ?? "Unknown",
            indexText: "\(displayIndex) / \(totalCount)",
            cameraModel: meta.camera,
            focalLength: meta.focal,
            aperture: meta.aperture,
            iso: meta.iso,
            gpsCoords: meta.gps
        )
    }

    private func fetchMetadata(for url: URL) -> (camera: String?, focal: String?, aperture: String?, iso: String?, gps: String?) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return (nil, nil, nil, nil, nil)
        }
        
        var camera: String? = nil
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = tiffDict[kCGImagePropertyTIFFMake] as? String ?? ""
            let model = tiffDict[kCGImagePropertyTIFFModel] as? String ?? ""
            if !make.isEmpty || !model.isEmpty {
                let cleanMake = make.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if cleanModel.hasPrefix(cleanMake) {
                    camera = cleanModel
                } else if cleanMake.isEmpty {
                    camera = cleanModel
                } else {
                    camera = "\(cleanMake) \(cleanModel)"
                }
            }
        }
        
        var focal: String? = nil
        var aperture: String? = nil
        var iso: String? = nil
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let fNumber = exifDict[kCGImagePropertyExifFNumber] as? Double {
                aperture = String(format: "f/%.1f", fNumber)
            }
            if let len = exifDict[kCGImagePropertyExifFocalLength] as? Double {
                focal = String(format: "%.1f mm", len)
            }
            if let isoRatings = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [Int], let firstIso = isoRatings.first {
                iso = "ISO \(firstIso)"
            } else if let isoRatings = exifDict[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let firstIso = isoRatings.first {
                iso = "ISO \(firstIso.intValue)"
            }
        }
        
        var gps: String? = nil
        if let gpsDict = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gpsDict[kCGImagePropertyGPSLatitude] as? Double,
               let latRef = gpsDict[kCGImagePropertyGPSLatitudeRef] as? String,
               let lon = gpsDict[kCGImagePropertyGPSLongitude] as? Double,
               let lonRef = gpsDict[kCGImagePropertyGPSLongitudeRef] as? String {
                gps = String(format: "%.4f°%@, %.4f°%@", lat, latRef, lon, lonRef)
            }
        }
        
        return (camera, focal, aperture, iso, gps)
    }

    // MARK: Init
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenURL(_:)),
            name: .openImageURL,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleExecuteCrop(_:)),
            name: .executeCrop,
            object: nil
        )
        checkHomeFolderAccess()
    }

    @objc private func handleExecuteCrop(_ notification: Notification) {
        guard let rect = notification.object as? CGRect else { return }
        cropCurrentImage(to: rect)
    }

    deinit {
        stopAccessingAll()
    }

    @objc private func handleOpenURL(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        openImage(url)
    }

    // MARK: - Public API

    /// Load all supported images from a folder, sorted by filename.
    func loadImages(from folder: URL) {
        let fm = FileManager.default
        do {
            let entries = try fm.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )

            let urls = entries
                .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
                .sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
                }

            images    = urls
            folderURL = folder
            folderAuthorized = true
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError {
                folderURL = folder
                folderAuthorized = false
                images = []
            }
        }
    }

    /// Open a specific image file: load its sibling images and display it.
    func openImage(_ url: URL) {
        guard hasChanges ? confirmDiscardChangesIfNeeded() : true else { return }
        
        let std    = url.standardizedFileURL
        let folder = std.deletingLastPathComponent()
        
        stopAccessingAll()
        _ = tryResolveBookmark(for: folder)
        startAccessing(std)
        
        loadImages(from: folder)

        if let idx = images.firstIndex(where: { $0.standardizedFileURL == std }) {
            currentIndex = idx
        } else {
            currentIndex = 0
            if images.isEmpty {
                images = [std]
            }
        }
        loadCurrentImage()
    }

    /// Navigate to the next image (wraps around).
    func goToNext() {
        guard hasChanges ? confirmDiscardChangesIfNeeded() : true else { return }
        guard hasImages else { return }
        currentIndex = (currentIndex + 1) % images.count
        loadCurrentImage()
    }

    /// Navigate to the previous image (wraps around).
    func goToPrevious() {
        guard hasChanges ? confirmDiscardChangesIfNeeded() : true else { return }
        guard hasImages else { return }
        currentIndex = (currentIndex - 1 + images.count) % images.count
        loadCurrentImage()
    }

    /// Present an NSOpenPanel so the user can pick an image file.
    func openFilePicker() {
        guard hasChanges ? confirmDiscardChangesIfNeeded() : true else { return }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = false
        panel.canChooseFiles          = true
        panel.allowedContentTypes     = Self.supportedExtensions
            .compactMap { UTType(filenameExtension: $0) }

        if panel.runModal() == .OK, let url = panel.url {
            openImage(url)
        }
    }

    /// Present an NSOpenPanel so the user can pick a folder.
    func openFolderPicker() {
        guard hasChanges ? confirmDiscardChangesIfNeeded() : true else { return }
        
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false

        if panel.runModal() == .OK, let url = panel.url {
            stopAccessingAll()
            startAccessing(url)
            saveBookmark(for: url)
            
            loadImages(from: url)
            currentIndex = 0
            loadCurrentImage()
        }
    }

    // MARK: - Sandbox Security Bookmarks & Active Scoped Access
    /// Refcount of successful startAccessingSecurityScopedResource calls per URL.
    nonisolated(unsafe) private var activeScopedURLs: [URL: Int] = [:]

    /// Canonical path for bookmark dictionary keys (resolves symlinks like /tmp → /private/tmp).
    private func canonicalPath(for url: URL) -> String {
        let std = url.standardizedFileURL
        let resolved = std.resolvingSymlinksInPath()
        return resolved.path
    }

    func startAccessing(_ url: URL) {
        let std = url.standardizedFileURL
        if std.startAccessingSecurityScopedResource() {
            activeScopedURLs[std, default: 0] += 1
        }
    }

    nonisolated func stopAccessingAll() {
        for (url, count) in activeScopedURLs {
            for _ in 0..<count {
                url.stopAccessingSecurityScopedResource()
            }
        }
        activeScopedURLs.removeAll()
    }

    private func tryResolveBookmark(for folderURL: URL) -> Bool {
        var currentURL = folderURL.standardizedFileURL.resolvingSymlinksInPath()
        let bookmarksKey = "secureBookmarks"

        while true {
            let path = canonicalPath(for: currentURL)
            if let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarksKey) as? [String: Data],
               let bookmarkData = bookmarks[path] {
                do {
                    var isStale = false
                    let resolvedURL = try URL(
                        resolvingBookmarkData: bookmarkData,
                        options: .withSecurityScope,
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )

                    if isStale {
                        // Re-create bookmark under the resolved URL's canonical path.
                        if let newBookmarkData = try? resolvedURL.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil,
                            relativeTo: nil
                        ) {
                            var updatedBookmarks = bookmarks
                            let newPath = canonicalPath(for: resolvedURL)
                            if newPath != path {
                                updatedBookmarks.removeValue(forKey: path)
                            }
                            updatedBookmarks[newPath] = newBookmarkData
                            UserDefaults.standard.set(updatedBookmarks, forKey: bookmarksKey)
                        }
                    }

                    if resolvedURL.startAccessingSecurityScopedResource() {
                        activeScopedURLs[resolvedURL, default: 0] += 1
                        return true
                    }
                } catch {
                    print("Failed to resolve bookmark for \(path): \(error)")
                }
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }
            currentURL = parentURL
        }

        return false
    }

    @discardableResult
    func saveBookmark(for folderURL: URL) -> Bool {
        let std = folderURL.standardizedFileURL
        do {
            let bookmarkData = try std.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = UserDefaults.standard.dictionary(forKey: "secureBookmarks") as? [String: Data] ?? [:]
            bookmarks[canonicalPath(for: std)] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: "secureBookmarks")
            return true
        } catch {
            print("Failed to save bookmark for \(std.path): \(error)")
            return false
        }
    }

    func requestFolderAuthorization() {
        guard let folderURL = folderURL else { return }

        // Capture the currently viewed file BEFORE reloading the folder listing.
        let keepURL = currentURL?.standardizedFileURL

        let panel = NSOpenPanel()
        panel.directoryURL = folderURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择并打开此文件夹，以授权 PicViewer 浏览该目录下的其他图片"
        panel.prompt = "授权访问"

        if panel.runModal() == .OK, let url = panel.url {
            _ = saveBookmark(for: url)
            startAccessing(url)
            loadImages(from: url)
            if let keep = keepURL {
                let keepPath = keep.path
                if let idx = images.firstIndex(where: { $0.standardizedFileURL.path == keepPath }) {
                    currentIndex = idx
                }
            }
            loadCurrentImage()
        }
    }

    func checkHomeFolderAccess() {
        let root = URL(fileURLWithPath: "/")
        // Only treat a persisted root bookmark as full-volume access.
        // Listing "/" can succeed under sandbox without user-selected root grant.
        hasHomeFolderAccess = tryResolveBookmark(for: root)
    }

    func requestHomeFolderAuthorization() {
        let root = URL(fileURLWithPath: "/")

        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请保持选择“Macintosh HD / 电脑”根目录（/），然后点击“授权访问”。\n此授权覆盖本机启动卷；外置磁盘需另行授权对应卷。"
        panel.prompt = "授权访问"

        if panel.runModal() == .OK, let url = panel.url {
            let chosen = url.standardizedFileURL.resolvingSymlinksInPath()
            // Only accept the real root of the boot volume.
            guard chosen.path == "/" else {
                presentAlert(
                    title: "未选择根目录",
                    message: "请在打开面板中选择根目录“/”，不要选择桌面、文稿等子文件夹。外置磁盘请使用“打开文件夹”单独授权。"
                )
                return
            }

            guard saveBookmark(for: chosen) else {
                presentAlert(
                    title: "无法保存授权",
                    message: "安全书签写入失败，请重试。若持续失败，请确认应用已正确签名并启用了 app-scope 书签权限。"
                )
                return
            }

            startAccessing(chosen)
            hasHomeFolderAccess = true

            let keepURL = currentURL?.standardizedFileURL
            if let folder = folderURL {
                loadImages(from: folder)
                if let keep = keepURL,
                   let idx = images.firstIndex(where: { $0.standardizedFileURL.path == keep.path }) {
                    currentIndex = idx
                }
                loadCurrentImage()
            }
        }
    }

    // MARK: - Image Editing Functions

    /// Compatible drawing context for rotate/flip (avoids silent failure on odd alpha/indexed formats).
    private func makeEditContext(width: Int, height: Int, reference: CGImage) -> CGContext? {
        let colorSpace = reference.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }

    private func warnUnsupportedEdit(_ action: String) {
        presentAlert(
            title: "无法\(action)",
            message: "当前图片像素格式不受支持，或图像数据无效。"
        )
    }

    func rotateCurrentImage(clockwise: Bool) {
        guard let currentImage = currentImage else { return }

        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            warnUnsupportedEdit("旋转")
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        let newSize = CGSize(width: height, height: width)

        guard let context = makeEditContext(width: height, height: width, reference: cgImage) else {
            warnUnsupportedEdit("旋转")
            return
        }

        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        if clockwise {
            context.rotate(by: -.pi / 2)
        } else {
            context.rotate(by: .pi / 2)
        }
        context.draw(cgImage, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))

        guard let rotatedCGImage = context.makeImage() else {
            warnUnsupportedEdit("旋转")
            return
        }
        self.currentImage = NSImage(cgImage: rotatedCGImage, size: newSize)
        self.hasChanges = true
    }

    func flipCurrentImage(horizontal: Bool) {
        guard let currentImage = currentImage else { return }

        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            warnUnsupportedEdit("翻转")
            return
        }
        let width = cgImage.width
        let height = cgImage.height
        let size = CGSize(width: width, height: height)

        guard let context = makeEditContext(width: width, height: height, reference: cgImage) else {
            warnUnsupportedEdit("翻转")
            return
        }

        if horizontal {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let flippedCGImage = context.makeImage() else {
            warnUnsupportedEdit("翻转")
            return
        }
        self.currentImage = NSImage(cgImage: flippedCGImage, size: size)
        self.hasChanges = true
    }

    func cropCurrentImage(to pixelRect: CGRect) {
        guard let currentImage = currentImage else { return }

        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let imgWidth = CGFloat(cgImage.width)
        let imgHeight = CGFloat(cgImage.height)

        let intersection = pixelRect.intersection(CGRect(x: 0, y: 0, width: imgWidth, height: imgHeight))
        guard !intersection.isNull, !intersection.isEmpty else { return }

        guard let croppedCGImage = cgImage.cropping(to: intersection) else { return }
        self.currentImage = NSImage(cgImage: croppedCGImage, size: intersection.size)
        self.hasChanges = true
    }

    /// Returns true when the file was written successfully.
    @discardableResult
    func saveChanges() -> Bool {
        guard hasChanges else { return true }
        guard let currentImage = currentImage, let url = currentURL else { return false }

        // Ensure folder-level write access when available.
        if let folder = folderURL {
            _ = tryResolveBookmark(for: folder)
        }
        startAccessing(url)

        do {
            guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NSError(domain: "PicViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法从当前图像生成可保存的像素数据"])
            }

            let ext = url.pathExtension.lowercased()
            // Animated / multi-frame formats: refuse destructive single-frame overwrite.
            if ["gif", "webp", "tiff", "tif"].contains(ext),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               CGImageSourceGetCount(source) > 1 {
                throw NSError(
                    domain: "PicViewer",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "暂不支持保存已编辑的多帧/动画图片（GIF、动画 WebP、多页 TIFF），以免丢失其余帧。请另存为 PNG/JPEG，或放弃修改。"]
                )
            }

            let uti: CFString
            switch ext {
            case "png": uti = UTType.png.identifier as CFString
            case "jpg", "jpeg": uti = UTType.jpeg.identifier as CFString
            case "webp": uti = UTType.webP.identifier as CFString
            case "gif": uti = UTType.gif.identifier as CFString
            case "bmp": uti = UTType.bmp.identifier as CFString
            case "tiff", "tif": uti = UTType.tiff.identifier as CFString
            case "heic", "heif": uti = UTType.heic.identifier as CFString
            default: uti = UTType.jpeg.identifier as CFString
            }

            // Preserve source metadata (EXIF/TIFF/GPS) where possible.
            var properties: [CFString: Any] = [:]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                properties = sourceProps
                // Pixels are already baked; force upright orientation.
                properties[kCGImagePropertyOrientation] = 1
                if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                    tiff[kCGImagePropertyTIFFOrientation] = 1
                    properties[kCGImagePropertyTIFFDictionary] = tiff
                }
            }

            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
                throw NSError(domain: "PicViewer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法创建图像写入目标（可能缺少写权限）"])
            }

            CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
            if !CGImageDestinationFinalize(destination) {
                throw NSError(domain: "PicViewer", code: 3, userInfo: [NSLocalizedDescriptionKey: "写入磁盘失败"])
            }

            self.hasChanges = false
            return true
        } catch {
            presentAlert(
                title: "无法保存修改",
                message: error.localizedDescription
            )
            return false
        }
    }

    func discardChanges() {
        loadCurrentImage()
        self.hasChanges = false
    }

    func confirmDiscardChangesIfNeeded() -> Bool {
        guard hasChanges else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "要保存对图片的修改吗？"
        alert.informativeText = "如果您不保存，所做的修改将会丢失。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // Only proceed when save actually succeeds.
            return saveChanges()
        } else if response == .alertSecondButtonReturn {
            discardChanges()
            return true
        } else {
            return false
        }
    }

    func setAsDefaultViewer() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            presentAlert(
                title: "Unable to update file associations",
                message: "The app bundle identifier is missing, so macOS could not register PicViewer as the default viewer."
            )
            return
        }

        let registeredURL = registeredApplicationURL()
        LSRegisterURL(registeredURL as CFURL, true)

        let contentTypes = Set(Self.supportedExtensions.compactMap(Self.preferredContentTypeIdentifier(forExtension:)))
        writeLaunchServicesOverrides(
            bundleIdentifier: bundleIdentifier,
            contentTypes: Array(contentTypes),
            extensions: Array(Self.supportedExtensions)
        )

        let failures = contentTypes.filter { identifier in
            let viewerStatus = LSSetDefaultRoleHandlerForContentType(
                identifier as CFString,
                .viewer,
                bundleIdentifier as CFString
            )
            let allStatus = LSSetDefaultRoleHandlerForContentType(
                identifier as CFString,
                .all,
                bundleIdentifier as CFString
            )
            return viewerStatus != noErr || allStatus != noErr
        }
        .sorted()

        if failures.isEmpty {
            presentAlert(
                title: "PicViewer is now the default viewer",
                message: "macOS has been asked to open supported image formats with PicViewer by default.\n\nRegistered app: \(registeredURL.path)"
            )
        } else {
            let list = failures.joined(separator: ", ")
            presentAlert(
                title: "Some file associations could not be updated",
                message: "macOS rejected these content types: \(list)"
            )
        }
    }

    func copyCurrentImageToPasteboard() {
        guard let currentImage else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([currentImage])
    }

    func revealCurrentImageInFinder() {
        guard let currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentURL])
    }

    private static let skipDeleteConfirmKey = "skipDeleteConfirmAfterFirst"

    func deleteCurrentImage() {
        guard let currentURL, let folderURL else { return }

        // Confirm if there are unsaved edits first.
        if hasChanges {
            guard confirmDiscardChangesIfNeeded() else { return }
        }

        // Trash confirmation only the first time; subsequent deletes go straight through.
        let skipConfirm = UserDefaults.standard.bool(forKey: Self.skipDeleteConfirmKey)
        if !skipConfirm {
            let confirm = NSAlert()
            confirm.alertStyle = .warning
            confirm.messageText = "要将此图片移到废纸篓吗？"
            confirm.informativeText = """
            \(currentURL.lastPathComponent)

            说明：这是首次删除确认。确认后，之后使用退格键 / Delete / 右键菜单删除时将不再弹出此对话框，图片会直接移到废纸篓。
            """
            confirm.addButton(withTitle: "移到废纸篓")
            confirm.addButton(withTitle: "取消")
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true, forKey: Self.skipDeleteConfirmKey)
        }

        // Ensure scoped write/trash access via parent bookmark when possible.
        _ = tryResolveBookmark(for: folderURL)
        startAccessing(currentURL)
        startAccessing(folderURL)

        let currentPath = currentURL.standardizedFileURL.path
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: currentURL, resultingItemURL: &resultingURL)

            hasChanges = false
            let previousIndex = currentIndex
            loadImages(from: folderURL)

            guard hasImages else {
                currentIndex = 0
                currentImage = nil
                isLoading = false
                return
            }

            currentIndex = min(previousIndex, images.count - 1)
            if images.indices.contains(currentIndex),
               images[currentIndex].standardizedFileURL.path == currentPath {
                currentIndex = min(currentIndex + 1, images.count - 1)
            }
            loadCurrentImage()
        } catch {
            presentAlert(
                title: "无法删除图片",
                message: error.localizedDescription
            )
        }
    }

    // MARK: - Private helpers

    func loadCurrentImage() {
        guard let url = currentURL else {
            currentImage = nil
            return
        }
        isLoading    = true
        currentImage = nil
        let capture  = url
        let expectedURL = capture.standardizedFileURL

        Task { [weak self, capture, expectedURL] in
            let img = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: capture)
            }.value

            // Only apply if we're still on the same image
            guard let self else { return }
            guard self.currentURL?.standardizedFileURL == expectedURL else { return }
            self.currentImage = img
            self.isLoading    = false
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func registeredApplicationURL() -> URL {
        let applicationsURL = URL(fileURLWithPath: "/Applications/PicViewer.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: applicationsURL.path) {
            return applicationsURL
        }
        return Bundle.main.bundleURL
    }

    private static func preferredContentTypeIdentifier(forExtension pathExtension: String) -> String? {
        UTType(filenameExtension: pathExtension)?.identifier
        ?? UTType(tag: pathExtension, tagClass: .filenameExtension, conformingTo: nil)?.identifier
    }

    private func writeLaunchServicesOverrides(bundleIdentifier: String, contentTypes: [String], extensions: [String]) {
        guard let defaults = UserDefaults(suiteName: Self.launchServicesDomain) else { return }

        let existingHandlers = (defaults.array(forKey: "LSHandlers") as? [[String: Any]]) ?? []
        let supportedContentTypes = Set(contentTypes)
        let supportedExtensions = Set(extensions.map { $0.lowercased() })

        let filteredHandlers = existingHandlers.filter { entry in
            if let type = entry["LSHandlerContentType"] as? String, supportedContentTypes.contains(type) {
                return false
            }

            if let tagClass = entry["LSHandlerContentTagClass"] as? String,
               tagClass == "public.filename-extension",
               let tag = entry["LSHandlerContentTag"] as? String,
               supportedExtensions.contains(tag.lowercased()) {
                return false
            }

            return true
        }

        let contentTypeHandlers: [[String: Any]] = contentTypes.sorted().map { identifier in
            [
                "LSHandlerContentType": identifier,
                "LSHandlerRoleAll": bundleIdentifier,
                "LSHandlerRoleViewer": bundleIdentifier,
            ]
        }

        let extensionHandlers: [[String: Any]] = extensions.sorted().map { pathExtension in
            [
                "LSHandlerContentTag": pathExtension,
                "LSHandlerContentTagClass": "public.filename-extension",
                "LSHandlerRoleAll": bundleIdentifier,
                "LSHandlerRoleViewer": bundleIdentifier,
            ]
        }

        defaults.set(filteredHandlers + contentTypeHandlers + extensionHandlers, forKey: "LSHandlers")
        defaults.synchronize()
    }

    private func imageDimensionsText(for image: NSImage?) -> String {
        guard let image else { return "Loading..." }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return "\(cgImage.width) × \(cgImage.height)"
        }

        if let rep = image.representations.first,
           rep.pixelsWide > 0,
           rep.pixelsHigh > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }

        let size = image.size
        if size.width > 0, size.height > 0 {
            return "\(Int(size.width)) × \(Int(size.height))"
        }

        return "Unknown"
    }
}
