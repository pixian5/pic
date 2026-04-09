import AppKit
import SwiftUI

// MARK: - ZoomableImageView
/// A SwiftUI wrapper around an NSScrollView that provides:
///   • Mouse-wheel zoom centred on the cursor
///   • Trackpad pinch-to-zoom (via NSScrollView.allowsMagnification)
///   • Two-finger trackpad scroll to pan
///   • Double-click → fullscreen callback
///   • Keyboard arrow keys → previous / next image
///   • Programmatic zoom commands via NotificationCenter

struct ZoomableImageView: NSViewRepresentable {

    let image:         NSImage
    var onPrevious:    () -> Void
    var onNext:        () -> Void
    var onDoubleClick: () -> Void

    func makeNSView(context: Context) -> PicScrollView {
        let scroll = PicScrollView()
        scroll.coordinator = context.coordinator
        context.coordinator.scrollView = scroll

        let documentView = PicDocumentView()
        let imageView = PicImageView()
        documentView.addSubview(imageView)

        scroll.documentView = documentView
        context.coordinator.documentView = documentView
        context.coordinator.imageView = imageView

        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = false
        scroll.allowsMagnification = false
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32.0
        scroll.backgroundColor = .black
        scroll.drawsBackground = true

        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomIn), name: .zoomIn, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomOut), name: .zoomOut, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomActual), name: .zoomActual, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomFit), name: .zoomFit, object: nil)

        context.coordinator.setImage(image)
        DispatchQueue.main.async {
            context.coordinator.applyInitialDisplayMode()
            scroll.focusForKeyboard()
        }

        return scroll
    }

    func updateNSView(_ scroll: PicScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onPrevious = onPrevious
        coordinator.onNext = onNext
        coordinator.onDoubleClick = onDoubleClick

        if coordinator.currentImage !== image {
            coordinator.setImage(image)
            DispatchQueue.main.async {
                coordinator.applyInitialDisplayMode()
                scroll.focusForKeyboard()
            }
        } else {
            coordinator.handleViewportDidChange()
            DispatchQueue.main.async {
                scroll.focusForKeyboard()
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevious: onPrevious, onNext: onNext, onDoubleClick: onDoubleClick)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {

        enum DisplayMode {
            case shortestEdgeFill
            case fitToWindow
            case actualSize
            case custom
        }

        var onPrevious: () -> Void
        var onNext: () -> Void
        var onDoubleClick: () -> Void

        weak var scrollView: PicScrollView?
        weak var documentView: PicDocumentView?
        weak var imageView: PicImageView?
        var currentImage: NSImage?
        var keyMonitor: Any?
        private var isUpdatingLayout = false
        var displayMode: DisplayMode = .fitToWindow
        var pendingDisplayMode: DisplayMode?
        private var lastViewportSize: CGSize = .zero
        private var imageNaturalSize: CGSize = .zero
        var zoomScale: CGFloat = 1.0

        init(onPrevious: @escaping () -> Void,
             onNext: @escaping () -> Void,
             onDoubleClick: @escaping () -> Void)
        {
            self.onPrevious = onPrevious
            self.onNext = onNext
            self.onDoubleClick = onDoubleClick
        }

        func setImage(_ image: NSImage) {
            currentImage = image
            guard let imageView else { return }
            imageNaturalSize = naturalSize(image)
            imageView.setImage(image)
            zoomScale = 1.0
            imageView.frame.size = imageNaturalSize
            displayMode = .fitToWindow
            pendingDisplayMode = .fitToWindow
            lastViewportSize = .zero
        }

        func applyInitialDisplayMode() {
            displayMode = .fitToWindow
            pendingDisplayMode = .fitToWindow
            applyDisplayModeIfNeeded(force: true)
        }

        func installKeyMonitorIfNeeded() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let scrollView = self.scrollView,
                      let window = scrollView.window,
                      event.window === window else {
                    return event
                }

                switch event.keyCode {
                case 123, 126:
                    self.onPrevious()
                    return nil
                case 124, 125:
                    self.onNext()
                    return nil
                case 53:
                    window.toggleFullScreen(nil)
                    return nil
                default:
                    return event
                }
            }
        }

        private func naturalSize(_ image: NSImage) -> CGSize {
            if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let width = cgImage.width
                let height = cgImage.height
                if width > 0, height > 0 {
                    return CGSize(width: width, height: height)
                }
            }

            if let rep = image.representations.first {
                let width = rep.pixelsWide
                let height = rep.pixelsHigh
                if width > 0, height > 0 {
                    return CGSize(width: width, height: height)
                }
            }

            let size = image.size
            if size.width > 0, size.height > 0 {
                return size
            }
            return .zero
        }

        func fitToWindow() {
            guard let scrollView else { return }
            let viewportSize = scrollView.contentSize
            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else { return }

            zoomScale = min(
                viewportSize.width / imageNaturalSize.width,
                viewportSize.height / imageNaturalSize.height
            ).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
            displayMode = .fitToWindow
            pendingDisplayMode = nil
            layoutDocumentForCurrentState()
            centerDocument()
        }

        func showImageUsingShortestEdge() {
            guard let scrollView else { return }
            let viewportSize = scrollView.contentSize
            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else { return }

            zoomScale = max(
                viewportSize.width / imageNaturalSize.width,
                viewportSize.height / imageNaturalSize.height
            ).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
            displayMode = .shortestEdgeFill
            pendingDisplayMode = nil
            layoutDocumentForCurrentState()
            centerDocument()
        }

        func applyDisplayModeIfNeeded(force: Bool = false) {
            let modeToApply = pendingDisplayMode ?? (force ? displayMode : nil)
            guard let mode = modeToApply else { return }
            guard let scrollView else { return }
            let viewportSize = scrollView.contentSize
            guard viewportSize.width > 0, viewportSize.height > 0 else { return }

            pendingDisplayMode = nil

            switch mode {
            case .shortestEdgeFill:
                showImageUsingShortestEdge()
            case .fitToWindow:
                fitToWindow()
            case .actualSize:
                zoomActual()
            case .custom:
                break
            }
        }

        func handleViewportDidChange() {
            let viewportSize = scrollView?.contentSize ?? .zero
            let viewportChanged = viewportSize != lastViewportSize
            lastViewportSize = viewportSize

            switch displayMode {
            case .shortestEdgeFill, .fitToWindow:
                if pendingDisplayMode != nil || viewportChanged {
                    applyDisplayModeIfNeeded(force: true)
                } else {
                    layoutDocumentForCurrentState()
                }
            case .actualSize, .custom:
                layoutDocumentForCurrentState()
            }
        }

        func markUserAdjustedZoom() {
            pendingDisplayMode = nil
            displayMode = .custom
        }

        func layoutDocumentForCurrentState() {
            guard !isUpdatingLayout,
                  let scrollView,
                  let documentView,
                  let imageView else { return }

            isUpdatingLayout = true
            defer { isUpdatingLayout = false }

            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0 else { return }

            let visibleSize = scrollView.contentView.bounds.size
            let displayedImageSize = NSSize(
                width: imageNaturalSize.width * zoomScale,
                height: imageNaturalSize.height * zoomScale
            )
            let documentSize = NSSize(
                width: max(displayedImageSize.width, visibleSize.width),
                height: max(displayedImageSize.height, visibleSize.height)
            )

            documentView.frame = NSRect(origin: .zero, size: documentSize)
            imageView.frame = NSRect(
                x: (documentSize.width - displayedImageSize.width) / 2,
                y: (documentSize.height - displayedImageSize.height) / 2,
                width: displayedImageSize.width,
                height: displayedImageSize.height
            )

            documentView.needsLayout = true
            documentView.needsDisplay = true
            imageView.needsDisplay = true
        }

        func centerDocument() {
            guard let scrollView,
                  let clipView = scrollView.contentView as NSClipView?,
                  let documentView = scrollView.documentView else { return }

            let documentSize = documentView.frame.size
            let visibleSize = scrollView.contentSize
            let origin = NSPoint(
                x: max(0, (documentSize.width - visibleSize.width) / 2),
                y: max(0, (documentSize.height - visibleSize.height) / 2)
            )

            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        @objc func zoomIn() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            animate {
                self.zoomScale = min(self.zoomScale * 1.25, scrollView.maxMagnification)
            }
            layoutDocumentForCurrentState()
        }

        @objc func zoomOut() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            animate {
                self.zoomScale = max(self.zoomScale * 0.8, scrollView.minMagnification)
            }
            layoutDocumentForCurrentState()
        }

        @objc func zoomActual() {
            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0 else { return }
            displayMode = .actualSize
            pendingDisplayMode = nil
            animate {
                self.zoomScale = 1.0
            }
            layoutDocumentForCurrentState()
            centerDocument()
        }

        @objc func zoomFit() {
            fitToWindow()
        }

        private func animate(_ block: @escaping () -> Void) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                block()
            }
        }

        deinit {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
            }
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - PicScrollView

final class PicScrollView: NSScrollView {

    weak var coordinator: ZoomableImageView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator?.installKeyMonitorIfNeeded()
        DispatchQueue.main.async { [weak self] in
            self?.coordinator?.applyDisplayModeIfNeeded(force: true)
            self?.focusForKeyboard()
        }
    }

    override func layout() {
        super.layout()
        coordinator?.handleViewportDidChange()
    }

    override func scrollWheel(with event: NSEvent) {
        focusForKeyboard()
        if event.phase == [] && event.momentumPhase == [] {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let factor = delta > 0 ? 1.12 : (1.0 / 1.12)
            coordinator?.markUserAdjustedZoom()
            coordinator?.zoomScale = ((coordinator?.zoomScale ?? 1.0) * factor).clamped(to: minMagnification...maxMagnification)
            coordinator?.layoutDocumentForCurrentState()
            coordinator?.centerDocument()
        } else {
            super.scrollWheel(with: event)
            coordinator?.layoutDocumentForCurrentState()
        }
    }

    override func magnify(with event: NSEvent) {
        focusForKeyboard()
        coordinator?.markUserAdjustedZoom()
        let factor = 1.0 + event.magnification
        coordinator?.zoomScale = ((coordinator?.zoomScale ?? 1.0) * factor).clamped(to: minMagnification...maxMagnification)
        coordinator?.layoutDocumentForCurrentState()
        coordinator?.centerDocument()
    }

    override func mouseDown(with event: NSEvent) {
        focusForKeyboard()
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126:
            coordinator?.onPrevious()
        case 124, 125:
            coordinator?.onNext()
        case 53:
            NSApp.keyWindow?.toggleFullScreen(nil)
        default:
            super.keyDown(with: event)
        }
    }

    func focusForKeyboard() {
        window?.makeFirstResponder(self)
    }
}

// MARK: - PicDocumentView

final class PicDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - PicImageView

final class PicImageView: NSView {

    override var acceptsFirstResponder: Bool { true }

    private var cgImage: CGImage?

    private var coordinator: ZoomableImageView.Coordinator? {
        (enclosingScrollView as? PicScrollView)?.coordinator
    }

    func setImage(_ image: NSImage) {
        cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let cgImage,
              let context = NSGraphicsContext.current?.cgContext else { return }

        context.interpolationQuality = .high
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(cgImage, in: CGRect(origin: .zero, size: bounds.size))
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        (enclosingScrollView as? PicScrollView)?.focusForKeyboard()
        if event.clickCount == 2 {
            coordinator?.onDoubleClick()
        } else {
            super.mouseDown(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        (enclosingScrollView as? PicScrollView)?.keyDown(with: event)
    }
}

// MARK: - Comparable clamping helper

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
