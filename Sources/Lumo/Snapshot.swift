import SwiftUI
import AppKit
// @preconcurrency: SCShareableContent carries no Sendable annotation when the
// deployment target is macOS 14, so returning it to this @MainActor type is an
// error in the classic build variant and fine in the Liquid Glass one. The import
// keeps one source tree building against both.
@preconcurrency import ScreenCaptureKit
import LumoKit

/// Renders the popover offscreen to PNG.
///
/// `screencapture` and UI scripting both need TCC permissions this app should not
/// be asking for, and design iteration should not depend on a human clicking the
/// menu bar. `ImageRenderer` draws the same view hierarchy into a bitmap in-process,
/// so the UI can be reviewed and regression-checked from a build script.
@MainActor
enum Snapshot {

    static func renderAll(to directory: URL) async throws {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // AppKit needs an initialised NSApplication before NSSwitch and friends
        // will lay out and draw.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        // Decide up front whether the compositor is available to us, because the
        // answer changes what the view tree should even contain. `glassEffect`
        // draws nothing in-process, so rendering it without a compositor capture
        // produces slider handles that are literally holes — worse than the
        // fallback. Probe once, then pick the knob that can actually be drawn.
        let canCaptureCompositedFrames = await compositorIsAvailable()

        // Optionally photograph the real desktop to sit behind the popover. Done
        // once, and before any of our own windows are on screen, so it catches the
        // wallpaper rather than a previous scenario's render.
        //
        // Off by default: the wallpaper is the operating system's artwork, and on a
        // pre-release build it is also unreleased artwork, so baking it into images
        // that get published is a decision rather than a default.
        if canCaptureCompositedFrames,
           ProcessInfo.processInfo.environment["LUMO_SNAPSHOT_BACKDROP"] == "desktop" {
            desktopBackdrop = await captureDesktop(on: NSScreen.main ?? NSScreen.screens[0])
            if desktopBackdrop == nil {
                FileHandle.standardError.write(
                    "could not photograph the desktop; using the neutral backdrop\n"
                        .data(using: .utf8)!)
            }
        }
        GlassSettings.isEnabled = canCaptureCompositedFrames
            && ProcessInfo.processInfo.environment["LUMO_SNAPSHOT_GLASS"] != "0"

        // Known snapshot limitation: an "on" NSSwitch renders with a grey track
        // here instead of the accent tint. The knob position is correct, so the
        // binding is right — it appears to need a running NSApp event loop, which
        // snapshot mode never enters. Neither making the window key nor activating
        // the app changes it. Verify switch tint in the live app, not from these.

        for (name, model) in scenarios() {
            for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua),
                                         ("light", NSAppearance.Name.aqua)] {
                try await render(MenuBarView(model: model, initialExpandedID: expandedFor(name),
                                             rendersFullHeight: true),
                                 appearance: appearance,
                                 to: directory.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }

    /// Expand the gradient lamp in one scenario so the palette and effect rows get
    /// rendered rather than only the collapsed row.
    private static func expandedFor(_ scenario: String) -> Light.ID? {
        scenario == "02-controls" ? SimulatedTransport.demoLights[1].id : nil
    }

    /// The states worth looking at — including the unhappy ones, which are the
    /// ones most likely to look wrong and least likely to be checked by hand.
    private static func scenarios() -> [(String, AppModel)] {
        let room = SimulatedTransport.demoRooms[0]
        let sceneNames = ["Evening", "Focus", "Movie"]
        let demoScenes = sceneNames.map {
            RoomScene(id: UUID(), name: $0, roomID: room.id, isEditable: true)
        }

        // 1. The everyday state: a room with lights and saved scenes.
        let normal = LightStore(transport: SimulatedTransport(),
                                initialLights: SimulatedTransport.demoLights,
                                initialRooms: [room],
                                initialScenes: demoScenes)

        // 2. Two rooms, to check the section dividers and per-room headers.
        let secondRoom = Room(id: UUID(), name: "Living room", archetype: "living_room",
                              lightIDs: [], groupedLightID: UUID())
        let twoRooms = LightStore(transport: SimulatedTransport(),
                                  initialLights: SimulatedTransport.demoLights,
                                  initialRooms: [room, secondRoom],
                                  initialScenes: demoScenes + [
                                    RoomScene(id: UUID(), name: "Sunset",
                                              roomID: secondRoom.id, isEditable: false)
                                  ])

        // 3. First run, nothing found yet.
        let empty = LightStore(transport: SimulatedTransport())

        // 4. One light out of range — must not look the same as "off".
        let mixed = LightStore(
            transport: SimulatedTransport(),
            initialLights: SimulatedTransport.demoLights.enumerated().map { index, light in
                var light = light
                if index == 1 { light.connection = .unreachable }
                return light
            },
            initialRooms: [room],
            initialScenes: demoScenes)

        return [
            ("01-rooms", AppModel(previewStore: twoRooms)),
            ("02-controls", AppModel(previewStore: normal)),
            ("03-empty", AppModel(previewStore: empty)),
            ("04-mixed", AppModel(previewStore: mixed)),
        ]
    }

    private static func render(_ view: some View, appearance: NSAppearance.Name,
                               to url: URL) async throws {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.layoutSubtreeIfNeeded()

        // Measure twice. The list reports its natural height through a preference,
        // which only reaches the view on a later pass — reading fittingSize once
        // captures the height from before that arrived, and the render comes out
        // truncated part-way down a row.
        var size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        hosting.layoutSubtreeIfNeeded()
        size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)

        // On screen, and captured through the window server rather than drawn by us.
        //
        // `cacheDisplay` walks the view tree and draws it into a bitmap in-process.
        // Liquid Glass is not drawn by the view tree at all — the compositor
        // produces it, sampling whatever sits behind the layer. So a cacheDisplay
        // capture came back with a *hole* where the slider handle should be, and the
        // documentation shots quietly showed the macOS 14 fallback while claiming to
        // show the app. Asking the compositor for the frame it actually rendered is
        // the only way to photograph glass.
        //
        // The backdrop matters as much as the capture. Glass refracts what is behind
        // it, so hosting the view on a flat opaque panel made the slider handles read
        // as dark blobs — nothing like the app, where they sit in a translucent
        // popover over the desktop. The window therefore uses the popover's own
        // material, over a fixed gradient standing in for a desktop, and the capture
        // takes that region of the display rather than the window alone: with
        // `.behindWindow` blending, the window by itself does not contain its own
        // appearance.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let backdrop = makeBackdropWindow(on: screen, appearance: appearance)
        backdrop.orderFrontRegardless()
        defer { backdrop.orderOut(nil) }

        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = .floating

        let material = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 12
        material.layer?.masksToBounds = true
        material.autoresizingMask = [.width, .height]
        hosting.frame = material.bounds
        hosting.autoresizingMask = [.width, .height]
        material.addSubview(hosting)
        window.contentView = material
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        // Let SwiftUI settle, then let the compositor draw. The window being on
        // screen does not mean its first frame exists yet, and capturing too early
        // yields an empty or half-drawn image.
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))

        // Compositor capture when it is permitted, in-process drawing when it is
        // not. The fallback is not silent: producing glass-less images while the
        // README claims to show the app is the exact failure this routine already
        // shipped once, so an unglassed run says so on every file.
        let bitmap: NSBitmapImageRep
        do {
            bitmap = NSBitmapImageRep(
                cgImage: try await capture(window: window, on: screen, size: size))
        } catch {
            guard let fallback = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                FileHandle.standardError.write(
                    "no bitmap for \(url.lastPathComponent)\n".data(using: .utf8)!)
                return
            }
            hosting.cacheDisplay(in: hosting.bounds, to: fallback)
            bitmap = fallback
            warnOnce(error)
            FileHandle.standardError.write(
                "  \(url.lastPathComponent): drawn in-process, Liquid Glass MISSING\n"
                    .data(using: .utf8)!)
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write("no png for \(url.lastPathComponent)\n".data(using: .utf8)!)
            return
        }

        do {
            try png.write(to: url)
            print("rendered \(url.path)")
        } catch {
            // Do not claim success on a failed write. The app bundle is sandboxed,
            // so writes outside its container fail here — run the unsandboxed
            // binary from .build for snapshots.
            FileHandle.standardError.write(
                "FAILED \(url.path): \(error.localizedDescription)\n".data(using: .utf8)!)
        }
    }

    /// Whether the window server will hand us composited frames.
    ///
    /// Asking costs one round-trip and saves rendering eight images with holes in
    /// them where the glass should be.
    private static func compositorIsAvailable() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            return true
        } catch {
            warnOnce(error)
            return false
        }
    }

    nonisolated(unsafe) private static var hasWarned = false

    /// Says once, loudly, that these images are not showing what the app looks like.
    private static func warnOnce(_ error: Error) {
        guard !hasWarned else { return }
        hasWarned = true
        FileHandle.standardError.write("""

            ────────────────────────────────────────────────────────────────────
            Screenshots will NOT show Liquid Glass.

            \(error.localizedDescription)

            Liquid Glass is composited by the window server, so it cannot be drawn
            in-process: the slider handles come out as holes and the images show the
            macOS 14 fallback instead. Grant Screen Recording to the binary being run
            (System Settings > Privacy & Security > Screen & System Audio Recording)
            and run again to capture the real thing.
            ────────────────────────────────────────────────────────────────────

            """.data(using: .utf8)!)
    }

    /// The real desktop, when the run asked for it. Captured once per run.
    private static var desktopBackdrop: CGImage?

    /// Photographs the desktop with every window excluded, so it is wallpaper only.
    private static func captureDesktop(on screen: NSScreen) async -> CGImage? {
        do {
            // `true` here excludes desktop windows from the LIST, which is exactly
            // what is wanted: the list then names the app windows to hide, and the
            // window that draws the wallpaper is not among them. Passing `false`
            // includes it, and excluding it too leaves a black rectangle.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
            let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            guard let display = content.displays.first(where: { $0.displayID == screenNumber })
                    ?? content.displays.first else { return nil }

            let configuration = SCStreamConfiguration()
            configuration.width = Int(screen.frame.width * screen.backingScaleFactor)
            configuration.height = Int(screen.frame.height * screen.backingScaleFactor)
            configuration.showsCursor = false
            configuration.captureResolution = .best

            // Excluding every shareable window leaves the wallpaper — including this
            // process's own windows, and whatever the user happens to have open.
            return try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display,
                                               excludingWindows: content.windows),
                configuration: configuration)
        } catch {
            return nil
        }
    }

    /// A fixed stand-in for the desktop.
    ///
    /// The popover material blends what is behind the window, so something has to be
    /// there — and it has to be the same thing every run, or the screenshots change
    /// with the wallpaper. Kept desaturated and matched to the appearance being
    /// rendered: a strongly coloured backdrop tints the whole popover through the
    /// material, which made the light shots read as mauve rather than light.
    private static func makeBackdropWindow(on screen: NSScreen,
                                           appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.level = .normal
        window.isOpaque = true
        window.hasShadow = false

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true

        // The real wallpaper when this run captured one; the gradient otherwise.
        if let desktop = desktopBackdrop {
            view.layer?.contents = desktop
            view.layer?.contentsGravity = .resizeAspectFill
            window.contentView = view
            return window
        }

        let gradient = CAGradientLayer()
        gradient.frame = view.bounds
        gradient.colors = appearance == .darkAqua
            ? [NSColor(red: 0.10, green: 0.11, blue: 0.14, alpha: 1).cgColor,
               NSColor(red: 0.17, green: 0.18, blue: 0.22, alpha: 1).cgColor,
               NSColor(red: 0.23, green: 0.22, blue: 0.26, alpha: 1).cgColor]
            : [NSColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 1).cgColor,
               NSColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1).cgColor,
               NSColor(red: 0.93, green: 0.92, blue: 0.94, alpha: 1).cgColor]
        view.layer?.addSublayer(gradient)
        window.contentView = view
        return window
    }

    /// Asks the window server for the composited pixels where the window is.
    ///
    /// A window-only filter would exclude the desktop the popover material blends,
    /// so this captures the display and crops to the window's rectangle instead.
    /// ScreenCaptureKit is the only supported route now — `CGWindowListCreateImage`
    /// is not merely deprecated on the macOS 26 SDK, it is unavailable. SCK needs
    /// Screen Recording permission even for your own windows, so the first snapshot
    /// run on a machine raises a TCC prompt; grant it once, to the binary being run,
    /// and it sticks as long as the signing identity is stable.
    private static func capture(window: NSWindow, on screen: NSScreen,
                                size: CGSize) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)

        let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == screenNumber })
                ?? content.displays.first else {
            throw SnapshotError.windowNotShareable
        }

        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        // Display capture is in top-left origin coordinates; NSWindow frames are
        // bottom-left and relative to the whole desktop.
        let frame = window.frame
        configuration.sourceRect = CGRect(x: frame.minX - screen.frame.minX,
                                          y: screen.frame.maxY - frame.maxY,
                                          width: size.width,
                                          height: size.height)
        configuration.width = Int(size.width * scale)
        configuration.height = Int(size.height * scale)
        configuration.showsCursor = false
        configuration.captureResolution = .best

        // Retry: back to back captures fail intermittently, and a failure here falls
        // back to an in-process draw, which silently drops the glass. Two of eight
        // images came out that way before this loop existed.
        var lastError: Error = SnapshotError.windowNotShareable
        for attempt in 0..<3 {
            do {
                return try await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []),
                    configuration: configuration)
            } catch {
                lastError = error
                try? await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        throw lastError
    }
}

enum SnapshotError: LocalizedError {
    case windowNotShareable

    var errorDescription: String? {
        switch self {
        case .windowNotShareable:
            return """
                The window server would not share the snapshot window. This is what \
                a missing Screen Recording permission looks like: grant it for the \
                binary you are running (System Settings > Privacy & Security > \
                Screen & System Audio Recording) and run again.
                """
        }
    }
}
