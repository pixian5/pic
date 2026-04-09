import Foundation
import AppKit
import CoreServices
import UniformTypeIdentifiers

// MARK: - ImageManager
/// Central model that owns the list of images in the current folder and the current index.
/// All mutations happen on the @MainActor.

@MainActor
final class ImageManager: ObservableObject {

    // MARK: Published state
    @Published var images:        [URL]     = []
    @Published var currentIndex:  Int       = 0
    @Published var currentImage:  NSImage?  = nil
    @Published var isLoading:     Bool      = false
    @Published var folderURL:     URL?      = nil

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

    // MARK: Init
    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOpenURL(_:)),
            name: .openImageURL,
            object: nil
        )
    }

    @objc private func handleOpenURL(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        openImage(url)
    }

    // MARK: - Public API

    /// Load all supported images from a folder, sorted by filename.
    func loadImages(from folder: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return }

        let urls = entries
            .filter { Self.supportedExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

        images    = urls
        folderURL = folder
    }

    /// Open a specific image file: load its sibling images and display it.
    func openImage(_ url: URL) {
        let std    = url.standardizedFileURL
        let folder = std.deletingLastPathComponent()
        loadImages(from: folder)

        if let idx = images.firstIndex(where: { $0.standardizedFileURL == std }) {
            currentIndex = idx
        } else {
            currentIndex = 0
        }
        loadCurrentImage()
    }

    /// Navigate to the next image (wraps around).
    func goToNext() {
        guard hasImages else { return }
        currentIndex = (currentIndex + 1) % images.count
        loadCurrentImage()
    }

    /// Navigate to the previous image (wraps around).
    func goToPrevious() {
        guard hasImages else { return }
        currentIndex = (currentIndex - 1 + images.count) % images.count
        loadCurrentImage()
    }

    /// Present an NSOpenPanel so the user can pick an image file.
    func openFilePicker() {
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
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories    = true
        panel.canChooseFiles          = false

        if panel.runModal() == .OK, let url = panel.url {
            loadImages(from: url)
            currentIndex = 0
            loadCurrentImage()
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
}
