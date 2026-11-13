// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import AppKit
import VestaKit

public enum MenuMetrics {
    public static let width: CGFloat = 330
    public static let chromeAllowance: CGFloat = 90
    public static func maximumBodyHeight(screenHeight: CGFloat) -> CGFloat {
        max(260, screenHeight - chromeAllowance)
    }
}

/// Natural height is resolved in layout, before NSPopover is shown. There is no
/// provisional height or asynchronous geometry feedback loop. Only a list that
/// actually exceeds the screen allowance becomes scrollable.
public struct PopoverList<Content: View>: View {
    let maximumHeight: CGFloat
    let fullHeight: Bool
    let content: Content

    public init(maximumHeight: CGFloat, fullHeight: Bool = false, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight; self.fullHeight = fullHeight
        self.content = content()
    }

    public var body: some View {
        if fullHeight {
            content.fixedSize(horizontal: false, vertical: true)
        } else {
            CappedHeightLayout(maximumHeight: maximumHeight) {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView { content }
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
    }
}

/// Measure the ideal content first, then propose the capped height. A flexible
/// maxHeight frame would expand even a short menu to the full screen allowance.
private struct CappedHeightLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let ideal = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: ideal.width, height: min(maximumHeight, ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(bounds.size))
    }
}

public struct MenuHeader<Controls: View>: View {
    let title: String
    let summary: String
    let symbol: String
    let isOn: Bool
    let controls: Controls

    public init(title: String, summary: String, symbol: String, isOn: Bool,
                @ViewBuilder controls: () -> Controls) {
        self.title = title; self.summary = summary; self.symbol = symbol; self.isOn = isOn
        self.controls = controls()
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.appGlyph)
                .foregroundStyle(isOn ? .yellow : .secondary)
                .frame(width: 30, height: 34)
                .background(.yellow.opacity(isOn ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 10))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.appTitle)
                Text(summary).font(.appSummary).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            controls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }
}

public struct DeviceSwatch: View {
    let color: ColorScience.RGB
    let isOn: Bool
    let ready: Bool
    let needsPairing: Bool
    let isPlug: Bool

    public init(color: ColorScience.RGB, isOn: Bool, ready: Bool, needsPairing: Bool = false, isPlug: Bool = false) {
        self.color = color; self.isOn = isOn; self.ready = ready
        self.needsPairing = needsPairing; self.isPlug = isPlug
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(isOn && ready ? Color(color) : Color.secondary.opacity(0.22))
                .frame(width: 22, height: 22)
                .overlay {
                    Circle().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.05)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
                }
                .shadow(color: isOn && ready ? Color(color).opacity(0.55) : .clear, radius: 4)
            if !ready {
                Image(systemName: needsPairing ? "lock.fill" : "antenna.radiowaves.left.and.right.slash")
                    .font(.controlGlyphBold).foregroundStyle(.secondary)
            } else if isPlug {
                Image(systemName: "powerplug.fill")
                    .font(.controlGlyphBold)
                    .foregroundStyle(isOn ? Color.black.opacity(0.65) : .secondary)
            }
        }
        .accessibilityHidden(true)
    }
}

public extension View {
    func deviceRowSurface(expanded: Bool, animatesExpansion: Bool = true) -> some View {
        modifier(DeviceRowSurface(expanded: expanded, animatesExpansion: animatesExpansion))
    }
}

private struct DeviceRowSurface: ViewModifier {
    let expanded: Bool
    let animatesExpansion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 10)
            .padding(.horizontal, 10)
            .background {
                if expanded {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(reduceTransparency ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                                                 : AnyShapeStyle(.primary.opacity(0.035)))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(.primary.opacity(contrast == .increased ? 0.4 : 0.08), lineWidth: 0.5)
                        }
                }
            }
            .padding(.horizontal, 8)
            .animation(animatesExpansion && !reduceMotion ? .snappy(duration: 0.22) : nil, value: expanded)
    }
}
