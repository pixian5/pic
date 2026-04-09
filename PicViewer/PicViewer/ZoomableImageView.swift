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
        let scroll       = PicScrollView()
        scroll.coordinator = context.coordinator
        context.coordinator.scrollView = scroll

        // ---- embedded image view ----
        let iv           = PicImageView()
        iv.imageScaling  = .scaleNone
        iv.animates      = true      // plays GIFs
        scroll.documentView = iv
        context.coordinator.imageView = iv

        // ---- scroll view config ----
        scroll.hasHorizontalScroller    = true
        scroll.hasVerticalScroller      = true
        scroll.autohidesScrollers       = true
        scroll.allowsMagnification      = true
        scroll.minMagnification         = 0.02
        scroll.maxMagnification         = 32.0
        scroll.backgroundColor          = .black
        scroll.drawsBackground          = true

        // ---- zoom notifications ----
        let nc = NotificationCenter.default
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomIn),     name: .zoomIn,     object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomOut),    name: .zoomOut,    object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomActual), name: .zoomActual, object: nil)
        nc.addObserver(context.coordinator, selector: #selector(Coordinator.zoomFit),    name: .zoomFit,    object: nil)

        // ---- first image ----
        context.coordinator.setImage(image)

        return scroll
    }

    func updateNSView(_ scroll: PicScrollView, context: Context) {
        let c          = context.coordinator
        c.onPrevious   = onPrevious
        c.onNext       = onNext
        c.onDoubleClick = onDoubleClick

        if c.currentImage !== image {
            c.setImage(image)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrevious: onPrevious, onNext: onNext, onDoubleClick: onDoubleClick)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {

        var onPrevious:    () -> Void
        var onNext:        () -> Void
        var onDoubleClick: () -> Void

        weak var scrollView: PicScrollView?
        weak var imageView:  PicImageView?
        var currentImage:    NSImage?

        init(onPrevious: @escaping () -> Void,
             onNext:     @escaping () -> Void,
             onDoubleClick: @escaping () -> Void)
        {
            self.onPrevious    = onPrevious
            self.onNext        = onNext
            self.onDoubleClick = onDoubleClick
        }

        // MARK: Image loading

        func setImage(_ image: NSImage) {
            currentImage = image
            guard let iv = imageView, let sv = scrollView else { return }
            iv.image      = image
            iv.frame.size = naturalSize(image)
            DispatchQueue.main.async { [weak self] in
                self?.fitToWindow()
            }
        }

        /// Returns the pixel size of the image (preferred) or the point size.
        private func naturalSize(_ image: NSImage) -> CGSize {
            if let rep = image.representations.first {
                let pw = rep.pixelsWide, ph = rep.pixelsHigh
                if pw > 0 && ph > 0 { return CGSize(width: pw, height: ph) }
            }
            return image.size
        }

        // MARK: Zoom helpers

        func fitToWindow() {
            guard let sv = scrollView, let iv = imageView else { return }
            let view  = sv.contentSize
            let img   = iv.frame.size
            guard img.width > 0, img.height > 0,
                  view.width > 0, view.height > 0 else { return }

            let scale = min(view.width / img.width, view.height / img.height, 1.0)
            sv.magnification = scale
            centerDocument()
        }

        func centerDocument() {
            guard let sv = scrollView, let cv = sv.contentView as? NSClipView,
                  let dv = sv.documentView else { return }
            let doc  = dv.frame.size
            let vis  = sv.contentSize
            let x    = max(0, (doc.width  - vis.width)  / 2)
            let y    = max(0, (doc.height - vis.height) / 2)
            cv.scroll(to: NSPoint(x: x, y: y))
            sv.reflectScrolledClipView(cv)
        }

        // MARK: Notification handlers

        @objc func zoomIn() {
            guard let sv = scrollView else { return }
            animate { sv.magnification = min(sv.magnification * 1.25, sv.maxMagnification) }
        }

        @objc func zoomOut() {
            guard let sv = scrollView else { return }
            animate { sv.magnification = max(sv.magnification * 0.8, sv.minMagnification) }
        }

        @objc func zoomActual() {
            guard let sv = scrollView else { return }
            animate { sv.magnification = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.centerDocument()
            }
        }

        @objc func zoomFit() {
            fitToWindow()
        }

        private func animate(_ block: @escaping () -> Void) {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                block()
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// MARK: - PicScrollView

/// Custom NSScrollView:
///   • Mouse-wheel → zoom centred on cursor
///   • Trackpad scroll → native pan (super)
final class PicScrollView: NSScrollView {

    weak var coordinator: ZoomableImageView.Coordinator?

    override var acceptsFirstResponder: Bool { true }

    override func scrollWheel(with event: NSEvent) {
        // NSScrollingPhase.none means a physical mouse wheel (discrete events)
        // Trackpad scrolls have a phase set (began / changed / ended)
        if event.phase == .none && event.momentumPhase == .none {
            let delta = event.scrollingDeltaY
            guard delta != 0 else { return }
            let factor  = delta > 0 ? 1.12 : (1.0 / 1.12)
            let pt      = contentView.convert(event.locationInWindow, from: nil)
            let newMag  = (magnification * factor).clamped(to: minMagnification...maxMagnification)
            setMagnification(newMag, centeredAt: pt)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: coordinator?.onPrevious()   // ← ↑
        case 124, 125: coordinator?.onNext()        // → ↓
        case 53:       // Esc – exit fullscreen
            NSApp.keyWindow?.toggleFullScreen(nil)
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - PicImageView

/// Custom NSImageView that fires double-click and forwards key events.
final class PicImageView: NSImageView {

    override var acceptsFirstResponder: Bool { true }

    private var coordinator: ZoomableImageView.Coordinator? {
        (enclosingScrollView as? PicScrollView)?.coordinator
    }

    override func mouseDown(with event: NSEvent) {
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
