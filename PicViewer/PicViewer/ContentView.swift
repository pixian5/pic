import SwiftUI
import AppKit

// MARK: - ContentView
/// Root view: dark canvas → zoomable image → translucent overlay UI.

struct ContentView: View {

    @EnvironmentObject var imageManager: ImageManager
    @State private var showOverlay = true
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var eventMonitors: [Any] = []

    var body: some View {
        ZStack {
            // ── Background ──────────────────────────────────────────────────
            Color.black.ignoresSafeArea()

            // ── Image area ──────────────────────────────────────────────────
            if imageManager.hasImages {
                imageContent
            } else {
                WelcomeView(imageManager: imageManager)
            }

            // ── Overlay UI ──────────────────────────────────────────────────
            OverlayUI(
                imageManager:      imageManager,
                onToggleFullscreen: toggleFullscreen,
                onPrevious:        { navigatePrevious() },
                onNext:            { navigateNext() }
            )
            .ignoresSafeArea()
            .opacity(showOverlay || !imageManager.hasImages ? 1 : 0)
            .allowsHitTesting(showOverlay || !imageManager.hasImages)
            .animation(.easeInOut(duration: 0.2), value: showOverlay)
        }
        // Receive global notifications (from menus / keyboard)
        .onReceive(NotificationCenter.default.publisher(for: .previousImage)) { _ in navigatePrevious() }
        .onReceive(NotificationCenter.default.publisher(for: .nextImage))     { _ in navigateNext()     }
        .onAppear  {
            restoreWindowFrame()
            updateWindowTitle()
            installActivityMonitors()
            if imageManager.hasImages {
                showOverlay = false
            }
        }
        .onDisappear {
            removeActivityMonitors()
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
            .ignoresSafeArea()
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

    // MARK: Overlay auto-hide

    private func bumpOverlayTimer() {
        withAnimation(.easeInOut(duration: 0.2)) { showOverlay = true }
        hideTask?.cancel()
        guard imageManager.hasImages else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.4)) { showOverlay = false }
            }
        }
    }

    private func installActivityMonitors() {
        removeActivityMonitors()
        NSApp.windows.first?.acceptsMouseMovedEvents = true

        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
            .keyDown
        ]

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            bumpOverlayTimer()
            return event
        }

        eventMonitors = [localMonitor].compactMap { $0 }
    }

    private func removeActivityMonitors() {
        hideTask?.cancel()
        hideTask = nil
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
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

// MARK: - OverlayUI
/// Translucent controls rendered on top of the image.

struct OverlayUI: View {
    @ObservedObject var imageManager: ImageManager
    var onToggleFullscreen: () -> Void
    var onPrevious:         () -> Void
    var onNext:             () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                topBar
                Spacer()
            }

            navRow

            VStack(spacing: 0) {
                Spacer()
                bottomBar
            }
        }
    }

    // MARK: Top toolbar

    private var topBar: some View {
        HStack(spacing: 8) {
            // Open file / folder
            Button { imageManager.openFilePicker() } label: {
                Image(systemName: "photo.badge.plus").font(.system(size: 14))
            }
            .help("Open Image (⌘O)")
            .glassButton()

            Button { imageManager.openFolderPicker() } label: {
                Image(systemName: "folder").font(.system(size: 14))
            }
            .help("Open Folder (⇧⌘O)")
            .glassButton()

            Button { imageManager.setAsDefaultViewer() } label: {
                Image(systemName: "checkmark.circle").font(.system(size: 14))
            }
            .help("Set PicViewer as the default viewer")
            .glassButton()

            Spacer()

            // Counter + filename
            if imageManager.hasImages {
                counterBadge
                if let name = imageManager.currentURL?.lastPathComponent {
                    Text(name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                        .pillStyle()
                }
            }

            Spacer()

            // Zoom controls
            Button { NotificationCenter.default.post(name: .zoomOut, object: nil) } label: {
                Image(systemName: "minus.magnifyingglass").font(.system(size: 14))
            }
            .help("Zoom Out (⌘-)")
            .glassButton()

            Button { NotificationCenter.default.post(name: .zoomFit, object: nil) } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass").font(.system(size: 14))
            }
            .help("Fit to Window (⌘9)")
            .glassButton()

            Button { NotificationCenter.default.post(name: .zoomIn, object: nil) } label: {
                Image(systemName: "plus.magnifyingglass").font(.system(size: 14))
            }
            .help("Zoom In (⌘+)")
            .glassButton()

            Button { onToggleFullscreen() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14))
            }
            .help("Toggle Fullscreen (⌃⌘F)")
            .glassButton()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.85))
    }

    // MARK: Navigation buttons (left / right)

    @ViewBuilder
    private var navRow: some View {
        if imageManager.hasImages {
            HStack {
                Button(action: onPrevious) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .semibold))
                }
                .help("Previous (← or ⌘[)")
                .navButton()
                .padding(.leading, 20)

                Spacer()

                Button(action: onNext) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 20, weight: .semibold))
                }
                .help("Next (→ or ⌘])")
                .navButton()
                .padding(.trailing, 20)
            }
        }
    }

    // MARK: Bottom bar (folder path)

    @ViewBuilder
    private var bottomBar: some View {
        if let folder = imageManager.folderURL {
            HStack {
                Spacer()
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(folder.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: 400)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial.opacity(0.85))
        }
    }

    // MARK: Counter badge

    private var counterBadge: some View {
        Text("\(imageManager.displayIndex) / \(imageManager.totalCount)")
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .pillStyle()
    }
}

// MARK: - View Modifiers / Button Styles

/// Rounded glass button used in the top toolbar.
struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed
                          ? Color.white.opacity(0.25)
                          : Color.black.opacity(0.45))
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Circular navigation button (prev / next).
struct NavButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(
                Circle()
                    .fill(configuration.isPressed
                          ? Color.white.opacity(0.3)
                          : Color.black.opacity(0.45))
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            )
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Convenience View extensions

private extension View {
    func glassButton() -> some View {
        self.buttonStyle(GlassButtonStyle())
    }
    func navButton() -> some View {
        self.buttonStyle(NavButtonStyle())
    }
    /// Small pill badge (counter / filename).
    func pillStyle() -> some View {
        self
            .foregroundStyle(.white)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.5)))
    }
}
