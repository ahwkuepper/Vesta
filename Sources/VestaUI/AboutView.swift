// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit

/// About Vesta.
///
/// The trademark disclaimer used to sit in the middle of the gear menu in a smaller
/// font, which is where legally required text goes when nobody has decided where it
/// belongs. It belongs here, with the version, the licence, and the source — the
/// things someone opens an About panel to find.
struct AboutView: View {

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "lightbulb.fill")
                    .font(.messageGlyph)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Vesta").font(.appTitle)
                    Text("Version \(version)")
                        .font(.appSummary)
                        .foregroundStyle(.secondary)
                }
            }

            Text("A menu-bar controller for Philips Hue that talks to the bridge on "
                 + "your network and to nothing else. No account, no cloud, no "
                 + "telemetry.")
                .font(.messageBody)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Licensed under Apache-2.0.")
                Text("Vesta is an independent project. It is not made, certified, "
                     + "endorsed or supported by Signify or Philips Hue. "
                     + "“Philips Hue” and “Hue” are their trademarks, used only to "
                     + "describe what Vesta works with.")
            }
            .font(.finePrint)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Link("Source", destination: Self.repository)
                Link("Releases", destination: Self.releases)
                Spacer()
            }
            .font(.messageBody)
        }
        .padding(20)
        .frame(width: 380)
    }

    // The only two URLs in the app. Nothing here makes a request — these are handed
    // to the browser on an explicit click, and Vesta learns nothing from either.
    // check-boundaries.sh allowlists them by exact value; any other host fails.
    static let repository = URL(string: "https://github.com/ahwkuepper/Vesta")!
    static let releases = URL(string: "https://github.com/ahwkuepper/Vesta/releases")!
}

/// Hosts the About panel in its own window.
///
/// A menu-bar app has no windows of its own, so one is made on demand and released
/// when closed.
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: AboutView())
        let panel = NSWindow(contentViewController: controller)
        panel.title = "About Vesta"
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
