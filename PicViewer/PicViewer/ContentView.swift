import SwiftUI
import AppKit

private let titleCountAccessoryIdentifier = NSUserInterfaceItemIdentifier("PicViewerTitleCountAccessory")

// MARK: - ContentView
/// Root view: dark canvas → zoomable image.

struct ContentView: View {

    @EnvironmentObject var imageManager: ImageManager
    @State private var showControls = false
    @State private var showInfoPanel = false
    @State private var hideControlsTask: Task<Void, Never>? = nil
    @State private var activityMonitor: Any? = nil
    @State private var keyMonitor: Any? = nil
    @State private var viewportSnapshot: ImageViewportSnapshot? = nil

    var body: some View {
        ZStack {
            Color.black

            if imageManager.hasImages {
                imageContent
                floatingControlsOverlay
            } else {
                WelcomeView(imageManager: imageManager)
            }
        }
        .contentShape(Rectangle())
        .onReceive(NotificationCenter.default.publisher(for: .previousImage)) { _ in navigatePrevious() }
        .onReceive(NotificationCenter.default.publisher(for: .nextImage)) { _ in navigateNext() }
        .onReceive(NotificationCenter.default.publisher(for: .imageViewportChanged)) { notification in
            viewportSnapshot = notification.object as? ImageViewportSnapshot
        }
        .onAppear {
            restoreWindowFrame()
            updateWindowTitle()
            installActivityMonitor()
            installKeyMonitor()
        }
        .onDisappear {
            removeActivityMonitor()
            removeKeyMonitor()
            saveWindowFrame()
        }
        .onChange(of: imageManager.currentURL?.path) { _, _ in
            updateWindowTitle()
            viewportSnapshot = nil
        }
        .onChange(of: imageManager.currentIndex) { _, _ in
            if imageManager.hasImages {
                bumpControlsVisibility()
            }
            updateWindowTitle()
        }
        .onChange(of: imageManager.totalCount) { _, _ in
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
            .contextMenu {
                Button("复制") {
                    imageManager.copyCurrentImageToPasteboard()
                }

                Button("打开文件夹") {
                    imageManager.revealCurrentImageInFinder()
                }

                Divider()

                Button("删除") {
                    imageManager.deleteCurrentImage()
                }
            }
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

    private func bumpControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showControls = true
        }

        hideControlsTask?.cancel()
        hideControlsTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls = false
                }
            }
        }
    }

    private func installActivityMonitor() {
        removeActivityMonitor()
        activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            if imageManager.hasImages {
                bumpControlsVisibility()
            }
            return event
        }
        NSApp.windows.first?.acceptsMouseMovedEvents = true
    }

    private func removeActivityMonitor() {
        hideControlsTask?.cancel()
        hideControlsTask = nil
        if let activityMonitor {
            NSEvent.removeMonitor(activityMonitor)
            self.activityMonitor = nil
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard imageManager.hasImages,
                  let window = NSApp.keyWindow,
                  event.window === window else {
                return event
            }

            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            switch (event.keyCode, modifiers) {
            case (8, [.command]):
                imageManager.copyCurrentImageToPasteboard()
                return nil
            case (51, []), (117, []):
                imageManager.deleteCurrentImage()
                return nil
            case (34, []):
                withAnimation(.easeInOut(duration: 0.18)) {
                    showInfoPanel.toggle()
                }
                bumpControlsVisibility()
                return nil
            case (44, []):
                NotificationCenter.default.post(name: .zoomToggleActualFit, object: nil)
                bumpControlsVisibility()
                return nil
            case (27, []), (27, [.shift]):
                NotificationCenter.default.post(name: .zoomOut, object: nil)
                bumpControlsVisibility()
                return nil
            case (24, []), (24, [.shift]):
                NotificationCenter.default.post(name: .zoomIn, object: nil)
                bumpControlsVisibility()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    @ViewBuilder
    private var floatingControlsOverlay: some View {
        ZStack {
            if showInfoPanel, let details = imageManager.currentImageDetails {
                HStack(spacing: 0) {
                    infoPanel(details)
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.leading, 12)
            }

            if let snapshot = viewportSnapshot, snapshot.shouldShowMiniMap {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        miniMap(snapshot)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 16)
            }

            if showControls {
                VStack {
                    HStack {
                        Spacer()
                        HStack(spacing: 10) {
                            overlayButton(systemName: "minus.magnifyingglass", help: "缩小") {
                                NotificationCenter.default.post(name: .zoomOut, object: nil)
                                bumpControlsVisibility()
                            }
                            overlayButton(systemName: "arrow.up.left.and.down.right.magnifyingglass", help: "原图尺寸") {
                                NotificationCenter.default.post(name: .zoomActual, object: nil)
                                bumpControlsVisibility()
                            }
                            overlayButton(systemName: "plus.magnifyingglass", help: "放大") {
                                NotificationCenter.default.post(name: .zoomIn, object: nil)
                                bumpControlsVisibility()
                            }
                            overlayButton(systemName: showInfoPanel ? "info.circle.fill" : "info.circle", help: "图片信息") {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    showInfoPanel.toggle()
                                }
                                bumpControlsVisibility()
                            }
                        }
                    }
                    Spacer()
                }
                .padding(.top, 12)
                .padding(.trailing, 12)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(true)
    }

    private func overlayButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.6))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func infoPanel(_ details: ImageManager.ImageDetails) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("图片信息")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            infoRow("名称", details.name)
            infoRow("序号", details.indexText)
            infoRow("尺寸", details.dimensionsText)
            infoRow("大小", details.fileSizeText)
            infoRow("格式", details.formatText)
            infoRow("修改时间", details.modifiedText)
            infoRow("路径", details.path)
        }
        .frame(width: 320, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
    }

    private func miniMap(_ snapshot: ImageViewportSnapshot) -> some View {
        let visible = snapshot.normalizedVisibleRect

        return ZStack(alignment: .topLeading) {
            Image(nsImage: snapshot.image)
                .resizable()
                .aspectRatio(snapshot.imageNaturalSize, contentMode: .fit)
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            GeometryReader { geometry in
                let size = geometry.size
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Color.white, lineWidth: 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
                    .frame(
                        width: max(visible.width * size.width, 10),
                        height: max(visible.height * size.height, 10)
                    )
                    .offset(
                        x: visible.minX * size.width,
                        y: visible.minY * size.height
                    )
            }
            .frame(width: 140, height: 140)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.62))
        )
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .textSelection(.enabled)
                .lineLimit(title == "路径" ? 3 : 1)
                .truncationMode(.middle)
        }
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
        updateTitlebarCountAccessory(for: window)
    }

    private func updateTitlebarCountAccessory(for window: NSWindow) {
        let countText = imageManager.hasImages ? "\(imageManager.displayIndex)/\(imageManager.totalCount)" : nil

        if let accessoryIndex = window.titlebarAccessoryViewControllers.firstIndex(where: { $0.identifier == titleCountAccessoryIdentifier }) {
            let accessory = window.titlebarAccessoryViewControllers[accessoryIndex]
            if let label = accessory.view.subviews.first as? NSTextField {
                label.stringValue = countText ?? ""
                label.sizeToFit()
                accessory.view.frame.size = label.fittingSize
            }

            if countText == nil {
                window.removeTitlebarAccessoryViewController(at: accessoryIndex)
            }
            return
        }

        guard let countText else { return }

        let label = NSTextField(labelWithString: countText)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.sizeToFit()

        let container = NSView(frame: NSRect(origin: .zero, size: label.fittingSize))
        label.frame = container.bounds
        label.autoresizingMask = [.width, .height]
        container.addSubview(label)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.identifier = titleCountAccessoryIdentifier
        accessory.layoutAttribute = .right
        accessory.view = container
        window.addTitlebarAccessoryViewController(accessory)
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
