import SwiftUI
import UniformTypeIdentifiers

enum DefaultImageDisplayMode: String, CaseIterable, Identifiable {
    case actualSize = "actualSize"
    case fillWindow = "fillWindow"
    case actualSizeOrFit = "actualSizeOrFit"

    static let userDefaultsKey = "defaultImageDisplayMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .actualSize:
            return "原尺寸"
        case .fillWindow:
            return "铺满窗口"
        case .actualSizeOrFit:
            return "原尺寸（最大铺满窗口）"
        }
    }

    static func current() -> DefaultImageDisplayMode {
        guard let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey),
              let mode = DefaultImageDisplayMode(rawValue: rawValue) else {
            return .fillWindow
        }
        return mode
    }
}

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

        Settings {
            SettingsView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink {
                    Text("设置…")
                }
                .keyboardShortcut(",", modifiers: .command)
            }

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

struct SettingsView: View {
    @AppStorage(DefaultImageDisplayMode.userDefaultsKey) private var defaultDisplayModeRawValue = DefaultImageDisplayMode.fillWindow.rawValue

    var body: some View {
        Form {
            Picker("图片默认尺寸", selection: $defaultDisplayModeRawValue) {
                ForEach(DefaultImageDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .pickerStyle(.radioGroup)
        }
        .padding(20)
        .frame(width: 420)
        .onChange(of: defaultDisplayModeRawValue) { _, _ in
            NotificationCenter.default.post(name: .defaultDisplayModeChanged, object: nil)
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
    static let zoomToggleActualFit = Notification.Name("zoomToggleActualFit")
    static let defaultDisplayModeChanged = Notification.Name("defaultDisplayModeChanged")
    static let previousImage  = Notification.Name("previousImage")
    static let nextImage      = Notification.Name("nextImage")
}
