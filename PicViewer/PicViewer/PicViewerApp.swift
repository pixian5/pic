import SwiftUI
import UniformTypeIdentifiers

// MARK: - App Entry Point

@main
struct PicViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var imageManager = ImageManager()

    var body: some Scene {
        Window("PicViewer", id: "main") {
            ContentView()
                .environmentObject(imageManager)
                .frame(minWidth: 480, minHeight: 320)
        }
        .commands {
            // Replace default New with Open
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") {
                    imageManager.openFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)

                Button("Open Folder…") {
                    imageManager.openFolderPicker()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // View menu
            CommandMenu("View") {
                Button("Zoom In") {
                    NotificationCenter.default.post(name: .zoomIn, object: nil)
                }
                .keyboardShortcut("+", modifiers: .command)

                Button("Zoom Out") {
                    NotificationCenter.default.post(name: .zoomOut, object: nil)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Actual Size") {
                    NotificationCenter.default.post(name: .zoomActual, object: nil)
                }
                .keyboardShortcut("0", modifiers: .command)

                Button("Fit to Window") {
                    NotificationCenter.default.post(name: .zoomFit, object: nil)
                }
                .keyboardShortcut("9", modifiers: .command)

                Divider()

                Button("Enter Full Screen") {
                    NSApp.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }

            // Go menu
            CommandMenu("Go") {
                Button("Previous Image") {
                    NotificationCenter.default.post(name: .previousImage, object: nil)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Next Image") {
                    NotificationCenter.default.post(name: .nextImage, object: nil)
                }
                .keyboardShortcut("]", modifiers: .command)
            }

            CommandMenu("Association") {
                Button("Set PicViewer as Default Viewer") {
                    imageManager.setAsDefaultViewer()
                }
            }
        }
    }
}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Called when a file is opened via Finder (double-click, Open With…)
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        NotificationCenter.default.post(name: .openImageURL, object: url)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let openImageURL   = Notification.Name("openImageURL")
    static let zoomIn         = Notification.Name("zoomIn")
    static let zoomOut        = Notification.Name("zoomOut")
    static let zoomActual     = Notification.Name("zoomActual")
    static let zoomFit        = Notification.Name("zoomFit")
    static let previousImage  = Notification.Name("previousImage")
    static let nextImage      = Notification.Name("nextImage")
}
