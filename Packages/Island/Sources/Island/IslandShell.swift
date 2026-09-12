//
//  IslandShell.swift
//  Island
//
//  The chrome every face is worn inside: the black shape, the size it is for
//  the face and the state it is in, the two places content can go, and the one
//  spring all of that moves on.
//
//  Collapsed, a face has no middle — the cutout is physically in the way — so
//  its content lives in the ears either side of it, and the shell is the only
//  thing that knows how far apart they are. Expanded, the cutout is above the
//  row and the face is one line across the whole width. That difference is
//  chrome, not content, which is why it is here and not in six faces that
//  would each have to remember it.
//
//  Both sets of content are always present and cross-faded rather than swapped.
//  A view that is inserted and removed cannot fade on its own schedule, and the
//  design gives the ears and the open face different ones — the ears are gone
//  before the face arrives, which is what stops the two reading as one pile of
//  overlapping text halfway through.
//
//  The view fills its window rather than asserting a size. The window is
//  whatever it has to be for the shell to be drawn without being cut off, and
//  during a close it is still the size the shell was: what has to stay put is
//  the black's top edge, which hangs from the top of the screen either way.
//

import DesignSystem
import SwiftUI

/// The island's shell, hosting one face.
public struct IslandShell<Leading: View, Trailing: View, Row: View>: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let geometry: IslandShellGeometry
    private let isExpanded: Bool
    private let leadingEar: () -> Leading
    private let trailingEar: () -> Trailing
    private let row: () -> Row

    /// - Parameters:
    ///   - leadingEar: what the collapsed shell shows left of the cutout.
    ///   - trailingEar: what it shows right of it.
    ///   - row: the single line the expanded shell shows instead.
    public init(
        geometry: IslandShellGeometry,
        isExpanded: Bool,
        @ViewBuilder leadingEar: @escaping () -> Leading,
        @ViewBuilder trailingEar: @escaping () -> Trailing,
        @ViewBuilder row: @escaping () -> Row
    ) {
        self.geometry = geometry
        self.isExpanded = isExpanded
        self.leadingEar = leadingEar
        self.trailingEar = trailingEar
        self.row = row
    }

    public var body: some View {
        // A `GeometryReader` rather than a flexible frame, because a flexible
        // frame did not hold the top. `maxHeight: .infinity` only fills a
        // proposal it is given one for, and the hosting view does not offer a
        // definite height — so the frame collapsed to the shell's own height
        // and the shell was centred in the window instead of hung from it.
        // Measured on the 14" M4 Pro during a first hover: 21 pt below the top
        // of its own window 92 ms in and 9 pt at 202 ms, with as much empty
        // space beneath it as above, in the model layer and the presentation
        // layer alike — so a layout, not an animation. What anybody watching
        // sees of that is the shell rising into the notch from below instead
        // of pouring out of it.
        //
        // A reader always fills what it is offered, and the frame below is
        // then a definite size with a definite alignment.
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                shell
                ears
                openRow
            }
            .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
            // The shell hangs from the top of its window by the margin the
            // flares or the pill's shadow need, and is centred across it.
            .padding(.top, geometry.shellInset.height)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .animation(shellMotion, value: geometry.shellSize)
        }
    }

    // MARK: The black

    @ViewBuilder
    private var shell: some View {
        if geometry.hangsFromBezel {
            // The flares are drawn outside the shape's own rect, which is why
            // this is framed to the shell and not to the window.
            IslandShellShape(cornerRadius: geometry.cornerRadius, flare: geometry.flare)
                .fill(EchoColor.Island.shell)
                .animation(shellMotion, value: geometry.cornerRadius)
                .animation(shellMotion, value: geometry.flare)
        } else {
            RoundedRectangle(cornerRadius: geometry.cornerRadius, style: .continuous)
                .fill(EchoColor.Island.shell)
                .shadow(
                    color: geometry.castsShadow ? EchoColor.Island.pillShadow : .clear,
                    radius: EchoLayout.islandPillShadowRadius,
                    y: EchoLayout.islandPillShadowOffset
                )
                .animation(shellMotion, value: geometry.cornerRadius)
        }
    }

    // MARK: What is on it

    /// Note where the fade sits: BELOW the frame, so it governs the fading and
    /// nothing else. Wrapped around the frame as well, the layer would resize
    /// on the fade's curve while the black beneath it resized on the spring,
    /// and a control pinned to the shell's trailing edge would visibly drift
    /// away from it and back over the length of the move.
    private var ears: some View {
        HStack(spacing: 0) {
            leadingEar().frame(maxWidth: .infinity, alignment: .leading)
            gap
            trailingEar().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, EchoLayout.islandEarInset)
        .opacity(isExpanded ? 0 : 1)
        // An ear that is on its way out is not a target. Without this the
        // faded-out layer still answers the pointer, over the open face.
        .allowsHitTesting(!isExpanded)
        .animation(reduceMotion ? nil : EchoMotion.islandEars, value: isExpanded)
        .frame(width: geometry.shellSize.width, height: geometry.shellSize.height)
        // Nothing on the island is drawn off it. An ear too narrow for what it
        // was given is a face to fix, and a face that quietly spilled its
        // contents onto the bezel would not look like one.
        .clipped()
    }

    /// The open face, in the part of the shell that hangs BELOW the cutout.
    ///
    /// The cutout is an absence of screen, not a dark patch of it: a row
    /// centred in the whole height puts its tallest content behind the camera,
    /// where it is not drawn at all. Reported from a 14" M4 Pro — the Record
    /// button's top corner was cut off by the notch, because the widest face
    /// leaves only ~70 pt clear of the cutout at each end and a right-aligned
    /// control is wider than that.
    private var openRow: some View {
        row()
            .padding(.leading, EchoLayout.islandRowLeadingInset)
            .padding(.trailing, EchoLayout.islandRowTrailingInset)
            .opacity(isExpanded ? 1 : 0)
            .offset(y: isExpanded ? 0 : EchoMotion.islandContentRise)
            .allowsHitTesting(isExpanded)
            .animation(
                reduceMotion ? nil : EchoMotion.islandContent(opening: isExpanded),
                value: isExpanded
            )
            // Never negative: a closing shell passes through heights shorter
            // than the band it is clearing, and the row is fading out by then
            // anyway.
            .frame(
                width: geometry.shellSize.width,
                height: max(0, geometry.shellSize.height - geometry.rowTopInset)
            )
            .clipped()
            .padding(.top, geometry.rowTopInset)
    }

    /// The hole between the ears.
    ///
    /// A fixed width on a notched screen — the cutout's own, read from that
    /// screen — and the shell is centred on the cutout, so a centred gap of
    /// exactly that width lands over it. The fallback pill has no hole, so the
    /// two ears simply take the ends of one row.
    @ViewBuilder
    private var gap: some View {
        if let cutoutWidth = geometry.cutoutWidth {
            // Never wider than the shell holding it. The idle shell is
            // NARROWER than the cutout — it hides inside it rather than
            // hanging off it — and a hole wider than its shell would squeeze
            // both ears to nothing and spill past the clip.
            Color.clear.frame(width: min(cutoutWidth, geometry.shellSize.width))
        } else {
            Spacer(minLength: EchoSpacing.s)
        }
    }

    /// One spring for the width, the height and the radius — or none at all.
    ///
    /// With Reduce Motion the design cuts: not a shorter spring, no spring.
    /// Someone who asked the system to stop moving things asked for the end
    /// state, and a fast animation is still an animation.
    ///
    /// UNVERIFIED on hardware: the machine the island has been run on has the
    /// setting off, and turning somebody's accessibility settings on and off
    /// underneath them is not a test. The tests cover the decision; what the
    /// cut looks like has not been watched (#121).
    private var shellMotion: Animation? {
        reduceMotion ? nil : EchoMotion.islandShell
    }
}
