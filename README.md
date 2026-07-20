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
| **Edit** | Rotate · flip · crop · save (⌘S) · discard (⌘Z)；保存时尽量保留 EXIF/GPS |
| **UI** | Auto-hiding overlay · image counter · filename · EXIF info panel · minimap |
| **Persistence** | Window size remembered between sessions；安全书签跨启动恢复目录授权 |

---

## Project Structure

```
PicViewer/
├── PicViewer.xcodeproj/          Xcode project
└── PicViewer/
    ├── PicViewerApp.swift         @main App, AppDelegate, Notification.Name
    ├── ImageManager.swift         @MainActor ObservableObject – folder loading, navigation, edit/save, bookmarks
    ├── ContentView.swift          Root SwiftUI view + overlay UI
    ├── ZoomableImageView.swift    NSViewRepresentable wrapping NSScrollView
    ├── Assets.xcassets/           App icon placeholder
    ├── Info.plist                 Bundle info + document type registration
    └── PicViewer.entitlements     App Sandbox + user-selected R/W + app-scope bookmarks
```

---

## How to Run in Xcode

1. Open `PicViewer/PicViewer.xcodeproj` in Xcode 15 or later.
2. Select the **PicViewer** scheme and choose **My Mac** as the destination.
3. Press **⌘R** to build and run.

> **Minimum deployment target:** macOS 14.0 (Sonoma)  
> **本机环境：** Apple Silicon（arm64）/ macOS 15+ 开发测试

---

## Sandbox & Authorization（重要）

应用启用了 **App Sandbox**，并使用 **security-scoped bookmarks** 做持久授权：

| 能力 | 说明 |
|---|---|
| 本机启动卷 | 首次可授权根目录 `/`，一次覆盖桌面、下载、文稿等本机路径 |
| 外置盘 / 网络卷 | **不会** 被 `/` 授权覆盖；请用「打开文件夹」对 `/Volumes/...` 单独授权 |
| 书签权限 | `com.apple.security.files.bookmarks.app-scope` + `files.user-selected.read-write` |
| 「以后再说」 | 仅跳过当前会话引导；下次启动若无根书签会再提示 |

### 本地安装运行（推荐）

开发测试请安装到 `/Applications`，便于文件关联与沙盒书签行为与正式分发一致：

```bash
# 构建（示例）
cd PicViewer
xcodebuild -project PicViewer.xcodeproj -scheme PicViewer -configuration Release \
  -derivedDataPath ./build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  build

# 结束旧进程并安装
pkill -x PicViewer || true
rm -rf /Applications/PicViewer.app
cp -R ./build/Build/Products/Release/PicViewer.app /Applications/
open /Applications/PicViewer.app
```

若 Gatekeeper 提示「已损坏」，且你确认来源可信：

```bash
xattr -dr com.apple.quarantine /Applications/PicViewer.app
```

> **注意：** 未正式签名 / 空 `DEVELOPMENT_TEAM` 时，security-scoped bookmark 跨启动稳定性可能弱于正式签名包；开发测试版可接受，正式分发请配置签名与公证。

### 编辑保存限制

- 无未保存修改时 **⌘S 不会重编码覆盖**。
- 保存失败时 **不会** 继续切图 / 退出，避免丢编辑。
- **多帧 / 动画**（多帧 GIF、动画 WebP、多页 TIFF）编辑后保存会被拒绝，防止塌成单帧；请另存为 PNG/JPEG 或放弃修改。
- 退出应用（⌘Q）若有未保存修改会弹出保存/不保存/取消。

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
| `/` | Toggle actual size / fit |
| `⌘S` | Save edits (only when dirty) |
| `⌘Z` | Discard edits |
| `Delete` / `Backspace` | Move current image to Trash（仅首次确认，之后直接删除） |
| `⌃⌘F` | Toggle fullscreen |
| `⌘O` | Open image file |
| `⇧⌘O` | Open folder |
| `Esc` | Exit fullscreen |

---

## File Association

Use `Association` → `Set PicViewer as Default Viewer` in the menu bar, or click the same button on the welcome screen.

For the most reliable association result, run the installed app from `/Applications/PicViewer.app` rather than a temporary build folder copy.

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
| `ImageManager` | Single source of truth. Folder scan, navigation, EXIF, edit/save, security-scoped bookmarks. All mutations are `@MainActor`. |
| `ZoomableImageView` | `NSViewRepresentable` + `PicScrollView`. Wheel/pinch zoom, pan, crop overlay. |
| `ContentView` | Overlay controls, auth banners, info panel, minimap. |
| `AppDelegate` | Finder open-URL bridge；退出前检查未保存修改。 |

---

## Future Enhancements

- Code signing & notarization for Gatekeeper-free distribution
- Thumbnail strip / filmstrip at the bottom
- Multi-frame / animated image edit pipeline
- Slideshow mode
- Copy / share actions
- Explicit external-volume authorization wizard
