import SwiftUI
import AppKit

// MARK: - ContentView
/// Root view: dark canvas → zoomable image.

struct ContentView: View {

    @EnvironmentObject var imageManager: ImageManager

    var body: some View {
        ZStack {
            Color.black

            if imageManager.hasImages {
                imageContent
            } else {
                WelcomeView(imageManager: imageManager)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .previousImage)) { _ in navigatePrevious() }
        .onReceive(NotificationCenter.default.publisher(for: .nextImage)) { _ in navigateNext() }
        .onAppear {
            restoreWindowFrame()
            updateWindowTitle()
        }
        .onDisappear {
            saveWindowFrame()
        }
        .onChange(of: imageManager.currentURL?.path) { _, _ in
            updateWindowTitle()
        }
    }

    // MARK: Image display with cross-fade

    @ViewBuilder
    private var imageContent: some View {
        if let img = imageManager.currentImage {
            ZoomableImageView(
                image:         img,
                onPrevious:    { navigatePrevious() },
                onNext:        { navigateNext()     },
                onDoubleClick: { toggleFullscreen() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Use .id so SwiftUI rebuilds the NSScrollView when the image changes,
            // producing a smooth fade between images.
            .id(imageManager.currentIndex)
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        } else if imageManager.isLoading {
            ProgressView()
                .progressViewStyle(.circular)
                .scaleEffect(1.5)
                .tint(.white)
        }
    }

    // MARK: Navigation helpers

    private func navigateNext() {
        imageManager.goToNext()
    }

    private func navigatePrevious() {
        imageManager.goToPrevious()
    }

    // MARK: Fullscreen

    private func toggleFullscreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    // MARK: Window frame persistence

    private func restoreWindowFrame() {
        guard let win   = NSApp.windows.first,
              let str   = UserDefaults.standard.string(forKey: "windowFrame"),
              str != "" else { return }
        let frame = NSRectFromString(str)
        if frame != .zero { win.setFrame(frame, display: true) }
    }

    private func saveWindowFrame() {
        if let win = NSApp.windows.first {
            UserDefaults.standard.set(NSStringFromRect(win.frame), forKey: "windowFrame")
        }
    }

    private func updateWindowTitle() {
        guard let window = NSApp.windows.first else { return }
        window.title = imageManager.currentURL?.lastPathComponent ?? "PicViewer"
    }
}

// MARK: - WelcomeView
/// Shown when no images are loaded yet.

struct WelcomeView: View {
    @ObservedObject var imageManager: ImageManager

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 72))
                .foregroundStyle(.secondary)

            Text("PicViewer")
                .font(.largeTitle.bold())

            Text("Open an image or folder to begin")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Open Image…") { imageManager.openFilePicker() }
                    .keyboardShortcut("o", modifiers: .command)
                    .controlSize(.large)

                Button("Open Folder…") { imageManager.openFolderPicker() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .controlSize(.large)

                Button("Set as Default Viewer") { imageManager.setAsDefaultViewer() }
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
