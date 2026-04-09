# PicViewer

A clean, native macOS image viewer built with **Swift + SwiftUI + AppKit**.

---

## Features

| Category | Details |
|---|---|
| **Formats** | jpg · jpeg · png · webp · gif (animated) · bmp · tiff · heic · heif |
| **Association** | Can register itself as the default viewer for all supported formats from inside the app |
| **Navigation** | ← → ↑ ↓ arrow keys · ⌘[ / ⌘] menu shortcuts · on-screen prev/next buttons |
| **Zoom** | Mouse-wheel zoom centred on cursor · trackpad pinch-to-zoom · ⌘+ / ⌘− / ⌘0 (actual size) / ⌘9 (fit to window) |
| **Pan** | Two-finger trackpad scroll · drag when zoomed in |
| **Fullscreen** | Double-click image · ⌃⌘F shortcut · on-screen button |
| **UI** | Auto-hiding overlay · image counter (3 / 25) · filename · folder path |
| **Persistence** | Window size remembered between sessions |

---

## Project Structure

```
PicViewer/
├── PicViewer.xcodeproj/          Xcode project
└── PicViewer/
    ├── PicViewerApp.swift         @main App, AppDelegate, Notification.Name
    ├── ImageManager.swift         @MainActor ObservableObject – folder loading, navigation
    ├── ContentView.swift          Root SwiftUI view + overlay UI
    ├── ZoomableImageView.swift    NSViewRepresentable wrapping NSScrollView
    ├── Assets.xcassets/           App icon placeholder
    ├── Info.plist                 Bundle info + document type registration
    └── PicViewer.entitlements     Sandboxing (read-only file access)
```

---

## How to Run in Xcode

1. Open `PicViewer/PicViewer.xcodeproj` in Xcode 15 or later.
2. Select the **PicViewer** scheme and choose **My Mac** as the destination.
3. Press **⌘R** to build and run.

> **Minimum deployment target:** macOS 14.0 (Sonoma)

---

## Keyboard Shortcuts

| Key | Action |
|---|---|
| `←` / `↑` | Previous image |
| `→` / `↓` | Next image |
| `⌘[` | Previous image (menu) |
| `⌘]` | Next image (menu) |
| `⌘+` | Zoom in |
| `⌘−` | Zoom out |
| `⌘0` | Actual size |
| `⌘9` | Fit to window |
| `⌃⌘F` | Toggle fullscreen |
| `⌘O` | Open image file |
| `⇧⌘O` | Open folder |
| `Esc` | Exit fullscreen |

---

## File Association

Use `Association` → `Set PicViewer as Default Viewer` in the menu bar, or click the same button on the welcome screen / top toolbar.

PicViewer will ask macOS to become the default viewer for:

- `jpg` / `jpeg`
- `png`
- `gif`
- `bmp`
- `tiff` / `tif`
- `heic` / `heif`
- `webp`

If Finder still shows the old app for some existing files, relaunch Finder once or reopen the file after registration so LaunchServices refreshes the association cache.

---

## CI / Releases

Every push to `main` / `master` triggers the **Build and Release** workflow (`.github/workflows/build-and-release.yml`):

1. Builds the app with `xcodebuild`, then applies ad-hoc signing for distribution compatibility.
2. Packages it as a `.dmg` (drag-to-install) **and** a `.zip`.
3. Creates a GitHub Release tagged `v{commit-count}` (e.g. `v3`, `v4`, …).

Download the latest release from the **Releases** tab and drag `PicViewer.app` to `/Applications`.  
If Gatekeeper prompts on first launch, right-click `PicViewer.app`, choose **Open**, then confirm **Open** in the dialog.

If macOS shows `PicViewer.app` is "damaged or incomplete", run:

```bash
xattr -dr com.apple.quarantine /Applications/PicViewer.app
```

Only do this for apps downloaded from the official GitHub Releases page of this repository and files you trust.

---

## Architecture Notes

| Module | Role |
|---|---|
| `ImageManager` | Single source of truth. Scans the folder, holds the `images` array and `currentIndex`. All mutations are `@MainActor`; image data is loaded on a background `Task`. |
| `ZoomableImageView` | `NSViewRepresentable` wrapping a custom `PicScrollView` (NSScrollView subclass). Mouse-wheel events are intercepted to zoom via `setMagnification(_:centeredAt:)`; trackpad scrolls use the native `super` path. Zoom commands are delivered via `NotificationCenter`. |
| `ContentView` | Composes the image view with a translucent overlay that auto-hides after 3 s of inactivity. Uses `.id(currentIndex)` to trigger SwiftUI's cross-fade transition when the image changes. |
| `OverlayUI` | Top toolbar (open / zoom / fullscreen buttons, counter badge), left/right navigation chevrons, and bottom folder-path bar. Uses `.ultraThinMaterial` for the macOS-native look. |

---

## Future Enhancements

- Code signing & notarization for Gatekeeper-free distribution
- Thumbnail strip / filmstrip at the bottom
- Metadata panel (EXIF, dimensions, file size)
- Slideshow mode
- Copy / share actions
- iCloud / network folder support
