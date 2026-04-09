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
        imageView.imageScaling = .scaleNone
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        documentView.addSubview(imageView)

        scroll.documentView = documentView
        context.coordinator.documentView = documentView
        context.coordinator.imageView = imageView

        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
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
        var displayMode: DisplayMode = .shortestEdgeFill
        var pendingDisplayMode: DisplayMode?
        private var lastViewportSize: CGSize = .zero

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
            imageView.image = image
            imageView.frame.size = naturalSize(image)
            displayMode = .shortestEdgeFill
            pendingDisplayMode = .shortestEdgeFill
            lastViewportSize = .zero
        }

        func applyInitialDisplayMode() {
            displayMode = .shortestEdgeFill
            pendingDisplayMode = .shortestEdgeFill
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
            let size = image.size
            if size.width > 0, size.height > 0 {
                return size
            }

            if let rep = image.representations.first {
                let width = rep.pixelsWide
                let height = rep.pixelsHigh
                if width > 0, height > 0 {
                    return CGSize(width: width, height: height)
                }
            }
            return .zero
        }

        func fitToWindow() {
            guard let scrollView, let imageView else { return }
            let viewportSize = scrollView.contentSize
            let imageSize = imageView.frame.size
            guard imageSize.width > 0, imageSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else { return }

            let fitMaximumMagnification = max(scrollView.maxMagnification, 1.0)
            let viewportShortestEdge = min(viewportSize.width, viewportSize.height)
            let imageShortestEdge = min(imageSize.width, imageSize.height)
            var scale = viewportShortestEdge / imageShortestEdge

            let widthLimit = viewportSize.width / (imageSize.width * scale)
            let heightLimit = viewportSize.height / (imageSize.height * scale)
            let shrinkLimit = min(widthLimit, heightLimit)
            if shrinkLimit < 1.0 {
                scale *= shrinkLimit
            }

            scale = scale.clamped(to: scrollView.minMagnification...fitMaximumMagnification)
            let centerPoint = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            displayMode = .fitToWindow
            pendingDisplayMode = nil
            scrollView.setMagnification(scale, centeredAt: centerPoint)
            layoutDocumentForCurrentState()
            centerDocument()
        }

        func showImageUsingShortestEdge() {
            guard let scrollView, let imageView else { return }
            let viewportSize = scrollView.contentSize
            let imageSize = imageView.frame.size
            guard imageSize.width > 0, imageSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else { return }

            let scale = max(
                viewportSize.width / imageSize.width,
                viewportSize.height / imageSize.height
            ).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
            let centerPoint = NSPoint(x: imageSize.width / 2, y: imageSize.height / 2)
            displayMode = .shortestEdgeFill
            pendingDisplayMode = nil
            scrollView.setMagnification(scale, centeredAt: centerPoint)
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

            let imageSize = imageView.frame.size
            guard imageSize.width > 0, imageSize.height > 0 else { return }

            let magnification = max(scrollView.magnification, 0.0001)
            let visibleRect = scrollView.documentVisibleRect
            let minimumWidth = max(scrollView.contentSize.width / magnification, visibleRect.width)
            let minimumHeight = max(scrollView.contentSize.height / magnification, visibleRect.height)
            let documentSize = NSSize(
                width: max(imageSize.width, minimumWidth),
                height: max(imageSize.height, minimumHeight)
            )

            documentView.frame = NSRect(origin: .zero, size: documentSize)
            imageView.frame = NSRect(
                x: (documentSize.width - imageSize.width) / 2,
                y: (documentSize.height - imageSize.height) / 2,
                width: imageSize.width,
                height: imageSize.height
            )

            documentView.needsLayout = true
        }

        func centerDocument() {
            guard let scrollView,
                  let clipView = scrollView.contentView as NSClipView?,
                  let documentView = scrollView.documentView else { return }

            let visibleRect = scrollView.documentVisibleRect
            let documentSize = documentView.frame.size
            let origin = NSPoint(
                x: max(0, (documentSize.width - visibleRect.width) / 2),
                y: max(0, (documentSize.height - visibleRect.height) / 2)
            )

            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        @objc func zoomIn() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            animate {
                scrollView.magnification = min(scrollView.magnification * 1.25, scrollView.maxMagnification)
            }
            layoutDocumentForCurrentState()
        }

        @objc func zoomOut() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            animate {
                scrollView.magnification = max(scrollView.magnification * 0.8, scrollView.minMagnification)
            }
            layoutDocumentForCurrentState()
        }

        @objc func zoomActual() {
            guard let scrollView else { return }
            displayMode = .actualSize
            pendingDisplayMode = nil
            animate {
                scrollView.magnification = 1.0
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
            let point = contentView.convert(event.locationInWindow, from: nil)
            let newMagnification = (magnification * factor).clamped(to: minMagnification...maxMagnification)
            coordinator?.markUserAdjustedZoom()
            setMagnification(newMagnification, centeredAt: point)
            coordinator?.layoutDocumentForCurrentState()
        } else {
            super.scrollWheel(with: event)
            coordinator?.layoutDocumentForCurrentState()
        }
    }

    override func magnify(with event: NSEvent) {
        focusForKeyboard()
        coordinator?.markUserAdjustedZoom()
        super.magnify(with: event)
        coordinator?.layoutDocumentForCurrentState()
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

final class PicImageView: NSImageView {

    override var acceptsFirstResponder: Bool { true }

    private var coordinator: ZoomableImageView.Coordinator? {
        (enclosingScrollView as? PicScrollView)?.coordinator
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
