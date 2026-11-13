// Copyright 2026 Andreas Kupper
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Bounds the complete page, including setup and errors, while keeping its header
/// visible. The host supplies the space below the status item before presentation.
public struct PopoverPage<Header: View, Content: View>: View {
    let maximumHeight: CGFloat
    let fullHeight: Bool
    let header: Header
    let content: Content

    public init(maximumHeight: CGFloat, fullHeight: Bool = false,
                @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.maximumHeight = maximumHeight; self.fullHeight = fullHeight
        self.header = header(); self.content = content()
    }

    public var body: some View {
        if fullHeight {
            VStack(spacing: 0) { header; content }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            PageLayout(maximumHeight: maximumHeight) {
                header.fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView { content }
                        .scrollBounceBehavior(.basedOnSize)
                }
            }
        }
    }
}

private struct PageLayout: Layout {
    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = ProposedViewSize(width: proposal.width, height: nil)
        let sizes = subviews.map { $0.sizeThatFits(ideal) }
        return CGSize(width: sizes.map(\.width).max() ?? 0,
                      height: min(maximumHeight, sizes.reduce(0) { $0 + $1.height }))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let headerHeight = min(bounds.height, subviews[0].sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)).height)
        subviews[0].place(at: bounds.origin, anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: headerHeight))
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + headerHeight), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: max(0, bounds.height - headerHeight)))
    }
}
