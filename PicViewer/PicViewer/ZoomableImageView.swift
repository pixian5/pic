import AppKit
import SwiftUI

struct ImageViewportSnapshot {
    let image: NSImage
    let imageRect: CGRect
    let visibleRect: CGRect
    let imageNaturalSize: CGSize

    var shouldShowMiniMap: Bool {
        visibleRect.width + 0.5 < imageRect.width || visibleRect.height + 0.5 < imageRect.height
    }

    var normalizedVisibleRect: CGRect {
        guard imageRect.width > 0, imageRect.height > 0 else { return .zero }

        let intersection = visibleRect.intersection(imageRect)
        guard !intersection.isNull, !intersection.isEmpty else { return .zero }

        return CGRect(
            x: (intersection.minX - imageRect.minX) / imageRect.width,
            y: (intersection.minY - imageRect.minY) / imageRect.height,
            width: intersection.width / imageRect.width,
            height: intersection.height / imageRect.height
        )
    }
}

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
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomToggleActualFit), name: .zoomToggleActualFit, object: nil)

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
            case actualSizeOrFit
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
            super.init()
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(handleDefaultDisplayModeChanged),
                name: .defaultDisplayModeChanged,
                object: nil
            )
            NotificationCenter.default.addObserver(self, selector: #selector(handleStartCropMode), name: .startCropMode, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleCancelCropMode), name: .cancelCropMode, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(handleApplyCropMode), name: .applyCropMode, object: nil)
        }

        var isCropMode: Bool {
            imageView?.isCropMode ?? false
        }

        @objc private func handleStartCropMode() {
            fitToWindow()
            guard let imageView = imageView else { return }
            imageView.isCropMode = true
            let b = imageView.bounds
            imageView.cropFrame = NSRect(
                x: b.minX + b.width * 0.1,
                y: b.minY + b.height * 0.1,
                width: b.width * 0.8,
                height: b.height * 0.8
            )
        }

        @objc private func handleCancelCropMode() {
            guard let imageView = imageView else { return }
            imageView.isCropMode = false
        }

        @objc private func handleApplyCropMode() {
            guard let imageView = imageView, imageView.isCropMode else { return }
            imageView.isCropMode = false
            
            let cropFrame = imageView.cropFrame
            let boundsSize = imageView.bounds.size
            guard boundsSize.width > 0, boundsSize.height > 0 else { return }
            
            let scale = imageNaturalSize.width / boundsSize.width
            let pixelRect = CGRect(
                x: cropFrame.origin.x * scale,
                y: cropFrame.origin.y * scale,
                width: cropFrame.size.width * scale,
                height: cropFrame.size.height * scale
            )
            
            NotificationCenter.default.post(name: .executeCrop, object: pixelRect)
        }

        func setImage(_ image: NSImage) {
            currentImage = image
            guard let imageView else { return }
            imageNaturalSize = naturalSize(image)
            imageView.setImage(image)
            zoomScale = 1.0
            imageView.frame.size = imageNaturalSize
            displayMode = defaultDisplayMode()
            pendingDisplayMode = displayMode
            lastViewportSize = .zero
            publishViewportSnapshot()
        }

        func applyInitialDisplayMode() {
            displayMode = defaultDisplayMode()
            pendingDisplayMode = displayMode
            applyDisplayModeIfNeeded(force: true)
        }

        private func defaultDisplayMode() -> DisplayMode {
            switch DefaultImageDisplayMode.current() {
            case .actualSize:
                return .actualSize
            case .fillWindow:
                return .shortestEdgeFill
            case .actualSizeOrFit:
                return .actualSizeOrFit
            }
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
            case .actualSizeOrFit:
                zoomActualSizeOrFit()
            case .custom:
                break
            }
        }

        func handleViewportDidChange() {
            let viewportSize = scrollView?.contentSize ?? .zero
            let viewportChanged = viewportSize != lastViewportSize
            lastViewportSize = viewportSize

            switch displayMode {
            case .shortestEdgeFill, .fitToWindow, .actualSizeOrFit:
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
            publishViewportSnapshot()
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
            publishViewportSnapshot()
        }

        private func currentViewportAnchor() -> CGPoint? {
            guard let scrollView,
                  let imageView else { return nil }

            let visibleRect = scrollView.documentVisibleRect
            let imageRect = imageView.frame
            let focusRect = visibleRect.intersection(imageRect)
            let referenceRect = (focusRect.isNull || focusRect.isEmpty) ? imageRect : focusRect

            guard referenceRect.width > 0,
                  referenceRect.height > 0,
                  imageRect.width > 0,
                  imageRect.height > 0 else { return nil }

            return CGPoint(
                x: (referenceRect.midX - imageRect.minX) / imageRect.width,
                y: (referenceRect.midY - imageRect.minY) / imageRect.height
            )
        }

        private func restoreViewport(anchor: CGPoint) {
            guard let scrollView,
                  let clipView = scrollView.contentView as NSClipView?,
                  let documentView = scrollView.documentView,
                  let imageView else { return }

            let visibleSize = clipView.bounds.size
            let imageRect = imageView.frame
            let targetPoint = CGPoint(
                x: imageRect.minX + (anchor.x * imageRect.width),
                y: imageRect.minY + (anchor.y * imageRect.height)
            )

            let maxX = max(0, documentView.frame.width - visibleSize.width)
            let maxY = max(0, documentView.frame.height - visibleSize.height)
            let origin = CGPoint(
                x: (targetPoint.x - visibleSize.width / 2).clamped(to: 0...maxX),
                y: (targetPoint.y - visibleSize.height / 2).clamped(to: 0...maxY)
            )

            clipView.scroll(to: origin)
            scrollView.reflectScrolledClipView(clipView)
            publishViewportSnapshot()
        }

        func updateZoomScalePreservingViewport(_ newScale: CGFloat) {
            let anchor = currentViewportAnchor()
            zoomScale = newScale
            layoutDocumentForCurrentState()

            if let anchor {
                restoreViewport(anchor: anchor)
            } else {
                centerDocument()
            }
        }

        @objc func zoomIn() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            updateZoomScalePreservingViewport(min(zoomScale * 1.25, scrollView.maxMagnification))
        }

        @objc func zoomOut() {
            guard let scrollView else { return }
            displayMode = .custom
            pendingDisplayMode = nil
            updateZoomScalePreservingViewport(max(zoomScale * 0.8, scrollView.minMagnification))
        }

        @objc func zoomActual() {
            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0 else { return }
            displayMode = .actualSize
            pendingDisplayMode = nil
            updateZoomScalePreservingViewport(1.0)
        }

        @objc func zoomActualSizeOrFit() {
            guard let scrollView else { return }
            let viewportSize = scrollView.contentSize
            guard imageNaturalSize.width > 0, imageNaturalSize.height > 0,
                  viewportSize.width > 0, viewportSize.height > 0 else { return }

            let fitScale = min(
                viewportSize.width / imageNaturalSize.width,
                viewportSize.height / imageNaturalSize.height
            )

            displayMode = .actualSizeOrFit
            pendingDisplayMode = nil
            zoomScale = min(1.0, fitScale).clamped(to: scrollView.minMagnification...scrollView.maxMagnification)
            layoutDocumentForCurrentState()
            centerDocument()
        }

        @objc func zoomFit() {
            fitToWindow()
        }

        @objc func zoomToggleActualFit() {
            if displayMode == .actualSize || abs(zoomScale - 1.0) < 0.0001 {
                fitToWindow()
            } else {
                zoomActual()
            }
        }

        func pan(by delta: CGPoint) {
            guard let scrollView,
                  let clipView = scrollView.contentView as NSClipView?,
                  let documentView = scrollView.documentView else { return }

            let documentSize = documentView.frame.size
            let visibleSize = clipView.bounds.size
            let maxX = max(0, documentSize.width - visibleSize.width)
            let maxY = max(0, documentSize.height - visibleSize.height)

            let nextOrigin = CGPoint(
                x: (clipView.bounds.origin.x - delta.x).clamped(to: 0...maxX),
                y: (clipView.bounds.origin.y - delta.y).clamped(to: 0...maxY)
            )

            clipView.scroll(to: nextOrigin)
            scrollView.reflectScrolledClipView(clipView)
            publishViewportSnapshot()
        }

        private func publishViewportSnapshot() {
            guard let currentImage,
                  let scrollView,
                  let imageView else { return }

            let snapshot = ImageViewportSnapshot(
                image: currentImage,
                imageRect: imageView.frame,
                visibleRect: scrollView.documentVisibleRect,
                imageNaturalSize: imageNaturalSize
            )

            NotificationCenter.default.post(name: .imageViewportChanged, object: snapshot)
        }

        @objc private func handleDefaultDisplayModeChanged() {
            guard currentImage != nil else { return }
            applyInitialDisplayMode()
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
        if coordinator?.isCropMode == true { return }
        focusForKeyboard()
        if event.phase == [] && event.momentumPhase == [] {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let factor = delta > 0 ? 1.12 : (1.0 / 1.12)
            coordinator?.markUserAdjustedZoom()
            if let coordinator {
                let nextScale = (coordinator.zoomScale * factor).clamped(to: minMagnification...maxMagnification)
                coordinator.updateZoomScalePreservingViewport(nextScale)
            }
        } else {
            super.scrollWheel(with: event)
            coordinator?.layoutDocumentForCurrentState()
        }
    }

    override func magnify(with event: NSEvent) {
        if coordinator?.isCropMode == true { return }
        focusForKeyboard()
        coordinator?.markUserAdjustedZoom()
        let factor = 1.0 + event.magnification
        if let coordinator {
            let nextScale = (coordinator.zoomScale * factor).clamped(to: minMagnification...maxMagnification)
            coordinator.updateZoomScalePreservingViewport(nextScale)
        }
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
    var isCropMode: Bool = false {
        didSet { needsDisplay = true }
    }
    var cropFrame: NSRect = .zero {
        didSet { needsDisplay = true }
    }

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

        if isCropMode {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()

            // 1. Semitransparent dim overlay
            context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            context.fill(bounds)

            // 2. Clear crop box
            context.setBlendMode(.clear)
            context.setFillColor(NSColor.clear.cgColor)
            context.fill(cropFrame)
            context.setBlendMode(.normal)

            // 3. Draw border and 3x3 grid
            context.setStrokeColor(NSColor.white.cgColor)
            context.setLineWidth(2.0)
            context.stroke(cropFrame)

            // Grid lines
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            context.setLineWidth(1.0)
            let thirdWidth = cropFrame.width / 3.0
            context.strokeLineSegments(between: [
                CGPoint(x: cropFrame.minX + thirdWidth, y: cropFrame.minY),
                CGPoint(x: cropFrame.minX + thirdWidth, y: cropFrame.maxY)
            ])
            context.strokeLineSegments(between: [
                CGPoint(x: cropFrame.minX + thirdWidth * 2, y: cropFrame.minY),
                CGPoint(x: cropFrame.minX + thirdWidth * 2, y: cropFrame.maxY)
            ])

            let thirdHeight = cropFrame.height / 3.0
            context.strokeLineSegments(between: [
                CGPoint(x: cropFrame.minX, y: cropFrame.minY + thirdHeight),
                CGPoint(x: cropFrame.maxX, y: cropFrame.minY + thirdHeight)
            ])
            context.strokeLineSegments(between: [
                CGPoint(x: cropFrame.minX, y: cropFrame.minY + thirdHeight * 2),
                CGPoint(x: cropFrame.maxX, y: cropFrame.minY + thirdHeight * 2)
            ])

            // 4. Draw handles
            let handleSize: CGFloat = 10.0
            let handles = [
                NSRect(x: cropFrame.minX - handleSize/2, y: cropFrame.minY - handleSize/2, width: handleSize, height: handleSize),
                NSRect(x: cropFrame.maxX - handleSize/2, y: cropFrame.minY - handleSize/2, width: handleSize, height: handleSize),
                NSRect(x: cropFrame.minX - handleSize/2, y: cropFrame.maxY - handleSize/2, width: handleSize, height: handleSize),
                NSRect(x: cropFrame.maxX - handleSize/2, y: cropFrame.maxY - handleSize/2, width: handleSize, height: handleSize)
            ]
            context.setFillColor(NSColor.white.cgColor)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            context.setLineWidth(1.0)
            for handle in handles {
                context.fillEllipse(in: handle)
                context.strokeEllipse(in: handle)
            }

            context.restoreGState()
        }
    }

    enum CropHandle {
        case none
        case topLeft, topRight, bottomLeft, bottomRight
        case body
    }

    private func hitTestCropFrame(_ point: NSPoint) -> CropHandle {
        let handleSize: CGFloat = 20.0

        let topLeft = NSRect(x: cropFrame.minX - handleSize/2, y: cropFrame.minY - handleSize/2, width: handleSize, height: handleSize)
        let topRight = NSRect(x: cropFrame.maxX - handleSize/2, y: cropFrame.minY - handleSize/2, width: handleSize, height: handleSize)
        let bottomLeft = NSRect(x: cropFrame.minX - handleSize/2, y: cropFrame.maxY - handleSize/2, width: handleSize, height: handleSize)
        let bottomRight = NSRect(x: cropFrame.maxX - handleSize/2, y: cropFrame.maxY - handleSize/2, width: handleSize, height: handleSize)

        if topLeft.contains(point) { return .topLeft }
        if topRight.contains(point) { return .topRight }
        if bottomLeft.contains(point) { return .bottomLeft }
        if bottomRight.contains(point) { return .bottomRight }
        if cropFrame.contains(point) { return .body }

        return .none
    }

    private func constrainCropFrame(_ frame: NSRect) -> NSRect {
        var f = frame
        let minSize: CGFloat = 30.0

        if f.size.width < minSize { f.size.width = minSize }
        if f.size.height < minSize { f.size.height = minSize }

        if f.minX < bounds.minX {
            f.size.width += f.origin.x - bounds.minX
            f.origin.x = bounds.minX
        }
        if f.maxX > bounds.maxX {
            f.size.width = bounds.maxX - f.minX
        }
        if f.minY < bounds.minY {
            f.size.height += f.origin.y - bounds.minY
            f.origin.y = bounds.minY
        }
        if f.maxY > bounds.maxY {
            f.size.height = bounds.maxY - f.origin.y
        }

        return f
    }

    private func handleCropMouseDown(with event: NSEvent) {
        let startPoint = convert(event.locationInWindow, from: nil)
        let activeHandle = hitTestCropFrame(startPoint)
        guard activeHandle != .none else { return }

        var lastPoint = startPoint

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] trackedEvent, stop in
            guard let self = self, let trackedEvent = trackedEvent else { return }

            switch trackedEvent.type {
            case .leftMouseDragged:
                let currentPoint = self.convert(trackedEvent.locationInWindow, from: nil)
                let deltaX = currentPoint.x - lastPoint.x
                let deltaY = currentPoint.y - lastPoint.y
                lastPoint = currentPoint

                var newFrame = self.cropFrame
                switch activeHandle {
                case .topLeft:
                    newFrame.origin.x += deltaX
                    newFrame.size.width -= deltaX
                    newFrame.origin.y += deltaY
                    newFrame.size.height -= deltaY
                case .topRight:
                    newFrame.size.width += deltaX
                    newFrame.origin.y += deltaY
                    newFrame.size.height -= deltaY
                case .bottomLeft:
                    newFrame.origin.x += deltaX
                    newFrame.size.width -= deltaX
                    newFrame.size.height += deltaY
                case .bottomRight:
                    newFrame.size.width += deltaX
                    newFrame.size.height += deltaY
                case .body:
                    newFrame.origin.x += deltaX
                    newFrame.origin.y += deltaY
                case .none:
                    break
                }

                self.cropFrame = self.constrainCropFrame(newFrame)

            case .leftMouseUp:
                stop.pointee = true
            default:
                break
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        (enclosingScrollView as? PicScrollView)?.focusForKeyboard()
        if isCropMode {
            handleCropMouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            coordinator?.onDoubleClick()
            return
        }

        var previousLocation = event.locationInWindow

        window?.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: .infinity, mode: .eventTracking) { [weak self] trackedEvent, stop in
            guard let self = self, let trackedEvent = trackedEvent else { return }

            switch trackedEvent.type {
            case .leftMouseDragged:
                let location = trackedEvent.locationInWindow
                let delta = CGPoint(x: location.x - previousLocation.x, y: previousLocation.y - location.y)
                previousLocation = location
                self.coordinator?.pan(by: delta)
            case .leftMouseUp:
                stop.pointee = true
            default:
                break
            }
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

extension Notification.Name {
    static let imageViewportChanged = Notification.Name("imageViewportChanged")
    static let startCropMode = Notification.Name("startCropMode")
    static let cancelCropMode = Notification.Name("cancelCropMode")
    static let applyCropMode = Notification.Name("applyCropMode")
    static let executeCrop = Notification.Name("executeCrop")
}
