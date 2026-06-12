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
    nonisolated(unsafe) private var activeScopedURLs: Set<URL> = []

    func startAccessing(_ url: URL) {
        let std = url.standardizedFileURL
        if std.startAccessingSecurityScopedResource() {
            activeScopedURLs.insert(std)
        }
    }

    nonisolated func stopAccessingAll() {
        for url in activeScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopedURLs.removeAll()
    }

    private func tryResolveBookmark(for folderURL: URL) -> Bool {
        let path = folderURL.standardizedFileURL.path
        guard let bookmarks = UserDefaults.standard.dictionary(forKey: "secureBookmarks") as? [String: Data],
              let bookmarkData = bookmarks[path] else {
            return false
        }
        
        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
            
            if isStale {
                let newBookmarkData = try resolvedURL.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
                var updatedBookmarks = bookmarks
                updatedBookmarks[path] = newBookmarkData
                UserDefaults.standard.set(updatedBookmarks, forKey: "secureBookmarks")
            }
            
            if resolvedURL.startAccessingSecurityScopedResource() {
                activeScopedURLs.insert(resolvedURL)
                return true
            }
        } catch {
            print("Failed to resolve bookmark for \(path): \(error)")
        }
        return false
    }
    
    func saveBookmark(for folderURL: URL) {
        let std = folderURL.standardizedFileURL
        do {
            let bookmarkData = try std.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            var bookmarks = UserDefaults.standard.dictionary(forKey: "secureBookmarks") as? [String: Data] ?? [:]
            bookmarks[std.path] = bookmarkData
            UserDefaults.standard.set(bookmarks, forKey: "secureBookmarks")
        } catch {
            print("Failed to save bookmark for \(std.path): \(error)")
        }
    }

    func requestFolderAuthorization() {
        guard let folderURL = folderURL else { return }
        
        let panel = NSOpenPanel()
        panel.directoryURL = folderURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请选择并打开此文件夹，以授权 PicViewer 浏览该目录下的其他图片"
        panel.prompt = "授权访问"
        
        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(for: url)
            startAccessing(url)
            loadImages(from: url)
            if let current = currentURL {
                let std = current.standardizedFileURL
                if let idx = images.firstIndex(where: { $0.standardizedFileURL == std }) {
                    currentIndex = idx
                }
            }
            loadCurrentImage()
        }
    }

    func checkHomeFolderAccess() {
        let root = URL(fileURLWithPath: "/")
        if tryResolveBookmark(for: root) {
            hasHomeFolderAccess = true
        } else {
            let fm = FileManager.default
            if (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) != nil {
                hasHomeFolderAccess = true
            } else {
                hasHomeFolderAccess = false
            }
        }
    }

    func requestHomeFolderAuthorization() {
        let root = URL(fileURLWithPath: "/")
        
        let panel = NSOpenPanel()
        panel.directoryURL = root
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "请直接点击“授权访问”以授权 PicViewer 访问您的整个硬盘"
        panel.prompt = "授权访问"
        
        if panel.runModal() == .OK, let url = panel.url {
            saveBookmark(for: url)
            startAccessing(url)
            hasHomeFolderAccess = true
            
            if let folder = folderURL {
                loadImages(from: folder)
            }
        }
    }

    // MARK: - Image Editing Functions
    func rotateCurrentImage(clockwise: Bool) {
        guard let currentImage = currentImage else { return }
        
        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let width = cgImage.width
        let height = cgImage.height
        let newSize = CGSize(width: height, height: width)
        
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: height,
                height: width,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else { return }
              
        context.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        if clockwise {
            context.rotate(by: -.pi / 2)
        } else {
            context.rotate(by: .pi / 2)
        }
        context.draw(cgImage, in: CGRect(x: -CGFloat(width) / 2, y: -CGFloat(height) / 2, width: CGFloat(width), height: CGFloat(height)))
        
        guard let rotatedCGImage = context.makeImage() else { return }
        self.currentImage = NSImage(cgImage: rotatedCGImage, size: newSize)
        self.hasChanges = true
    }

    func flipCurrentImage(horizontal: Bool) {
        guard let currentImage = currentImage else { return }
        
        guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let width = cgImage.width
        let height = cgImage.height
        let size = CGSize(width: width, height: height)
        
        guard let colorSpace = cgImage.colorSpace,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: cgImage.bitsPerComponent,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: cgImage.bitmapInfo.rawValue
              ) else { return }
              
        if horizontal {
            context.translateBy(x: CGFloat(width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
        }
        
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        guard let flippedCGImage = context.makeImage() else { return }
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

    func saveChanges() {
        guard let currentImage = currentImage, let url = currentURL else { return }
        
        startAccessing(url)
        
        do {
            guard let cgImage = currentImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw NSError(domain: "PicViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not get CGImage from NSImage"])
            }
            
            let uti: CFString
            switch url.pathExtension.lowercased() {
            case "png": uti = UTType.png.identifier as CFString
            case "jpg", "jpeg": uti = UTType.jpeg.identifier as CFString
            case "webp": uti = UTType.webP.identifier as CFString
            case "gif": uti = UTType.gif.identifier as CFString
            case "bmp": uti = UTType.bmp.identifier as CFString
            case "tiff", "tif": uti = UTType.tiff.identifier as CFString
            case "heic", "heif": uti = UTType.heic.identifier as CFString
            default: uti = UTType.jpeg.identifier as CFString
            }
            
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, uti, 1, nil) else {
                throw NSError(domain: "PicViewer", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create image destination"])
            }
            
            CGImageDestinationAddImage(destination, cgImage, nil)
            if !CGImageDestinationFinalize(destination) {
                throw NSError(domain: "PicViewer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to write image data to disk"])
            }
            
            self.hasChanges = false
        } catch {
            presentAlert(
                title: "无法保存修改",
                message: error.localizedDescription
            )
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
            saveChanges()
            return true
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

    func deleteCurrentImage() {
        guard let currentURL, let folderURL else { return }

        let currentPath = currentURL.standardizedFileURL.path
        do {
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: currentURL, resultingItemURL: &resultingURL)

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
