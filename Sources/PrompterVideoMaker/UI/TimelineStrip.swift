import AppKit
import SwiftUI

/// A draggable cue timeline: a windowed strip of the script's timing
/// (script-time space) for fine-tuning cue start/end times by dragging
/// blocks and their edges, instead of the segment list's steppers.
///
/// All timing edits go through `AppState`'s clamped APIs (`setStart`,
/// `setEnd`, `moveSegment`), which clamp against neighboring segments, so
/// overlaps are impossible no matter how the drag math above them behaves.
struct TimelineStrip: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("PVMTimelineSpan") private var windowSpan: Double = 30

    private enum DragKind {
        case move
        case resizeStart
        case resizeEnd
    }

    /// State for the in-progress drag: which segment/edge, plus the frozen
    /// window/scale so the strip doesn't recenter mid-drag and the pixel
    /// math stays stable even as the dragged block's own frame changes.
    private struct ActiveDrag {
        var id: UUID
        var kind: DragKind
        var windowStart: Double
        var pixelsPerSecond: CGFloat
        var lastTranslationWidth: CGFloat = 0
        /// For edge drags: how far (in points) the cursor was from the true
        /// edge when the drag began. The generous grab zones mean the cursor
        /// can start well inside the block, so the edge follows
        /// `cursor - grabOffset` instead of snapping to the cursor.
        var grabOffset: CGFloat = 0
    }

    /// Which part of a block a point falls in.
    private enum BlockZone: Equatable {
        case startHandle
        case middle
        case endHandle
    }

    private struct HoverTarget: Equatable {
        var id: UUID
        var zone: BlockZone
    }

    @State private var activeDrag: ActiveDrag?
    @State private var hoverTarget: HoverTarget?

    /// Width of the grab zone at each edge of a block `w` points wide: 16 pt
    /// for wide blocks, shrinking to 30% of the width (but never below 6 pt)
    /// so narrow blocks keep a middle move zone. Used for hit-testing, the
    /// cursor, and drawing (label padding / grip visibility).
    private func handleZone(forBlockWidth w: CGFloat) -> CGFloat {
        min(16, max(6, w * 0.3))
    }

    /// Grips are drawn only on blocks at least this wide.
    private let gripMinBlockWidth: CGFloat = 22
    private let gripWidth: CGFloat = 5
    private let gripInset: CGFloat = 3
    private let gripHeightFraction: CGFloat = 0.65
    private let rulerHeight: CGFloat = 14
    /// Taller when the audio waveform track is shown.
    private var stripHeight: CGFloat { appState.audioWaveform == nil ? 64 : 100 }
    private var waveLaneHeight: CGFloat { appState.audioWaveform == nil ? 0 : 32 }

    private struct Entry: Identifiable {
        let id: UUID
        let index: Int
        let segment: Segment
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geo in
                canvas(width: geo.size.width, height: geo.size.height)
            }
            .frame(minWidth: 80)

            Picker("", selection: $windowSpan) {
                Text("10s").tag(10.0)
                Text("30s").tag(30.0)
                Text("60s").tag(60.0)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .frame(width: 108)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: stripHeight)
    }

    // MARK: - Canvas

    @ViewBuilder
    private func canvas(width: CGFloat, height: CGFloat) -> some View {
        let windowStart = effectiveWindowStart
        let blocksTop = rulerHeight
        let blocksHeight = max(height - rulerHeight - waveLaneHeight, 0)

        ZStack(alignment: .topLeading) {
            // Empty-strip background: click seeks the playhead. Sits behind
            // everything else so blocks/ruler win hit-testing over it.
            Rectangle()
                .fill(Color.gray.opacity(0.08))
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let scriptTime = xToTime(value.location.x, windowStart: windowStart, width: width)
                            appState.seek(to: scriptTime + appState.project.style.leadIn)
                        }
                )

            rulerView(windowStart: windowStart, width: width)
                .frame(width: width, height: rulerHeight)
                .allowsHitTesting(false)

            ForEach(visibleSegments(windowStart: windowStart)) { entry in
                blockView(
                    entry: entry,
                    windowStart: windowStart,
                    width: width,
                    blocksTop: blocksTop,
                    blocksHeight: blocksHeight
                )
            }

            if let wave = appState.audioWaveform {
                waveformLane(wave: wave, windowStart: windowStart, width: width)
                    .frame(width: width, height: waveLaneHeight)
                    .offset(y: height - waveLaneHeight)
                    .allowsHitTesting(false)
            }

            playheadLine(windowStart: windowStart, width: width, height: height)
                .allowsHitTesting(false)

            dragReadout(windowStart: windowStart, width: width)
        }
        .frame(width: width, height: height)
        .coordinateSpace(name: "timelineCanvas")
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Ruler

    private func rulerView(windowStart: Double, width: CGFloat) -> some View {
        Canvas { context, size in
            let end = windowStart + windowSpan
            var t = (windowStart / 5).rounded(.down) * 5
            while t <= end {
                let x = timeToX(t, windowStart: windowStart, width: width)
                if x >= -24 && x <= size.width + 24 {
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: size.height - 5))
                    tick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(tick, with: .color(.secondary.opacity(0.6)), lineWidth: 1)
                    context.draw(
                        Text(rulerLabel(t)).font(.system(size: 9)).foregroundStyle(.secondary),
                        at: CGPoint(x: x, y: size.height - 6),
                        anchor: .bottom
                    )
                }
                t += 5
            }
        }
    }

    private func rulerLabel(_ t: Double) -> String {
        let sign = t < -0.001 ? "-" : ""
        let at = abs(t)
        let m = Int(at) / 60
        let s = Int(at) % 60
        return String(format: "%@%d:%02d", sign, m, s)
    }

    // MARK: - Blocks

    private func visibleSegments(windowStart: Double) -> [Entry] {
        let end = windowStart + windowSpan
        return appState.project.script.segments.enumerated().compactMap { index, segment in
            guard !EmphasisMarkup.strip(segment.text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            guard segment.end > windowStart, segment.start < end else { return nil }
            return Entry(id: segment.id, index: index, segment: segment)
        }
    }

    @ViewBuilder
    private func blockView(entry: Entry, windowStart: Double, width: CGFloat, blocksTop: CGFloat, blocksHeight: CGFloat) -> some View {
        let seg = entry.segment
        let block = BlockGeometry(
            rawXStart: timeToX(seg.start, windowStart: windowStart, width: width),
            rawXEnd: timeToX(seg.end, windowStart: windowStart, width: width),
            canvasWidth: width
        )
        let blockWidth = block.width
        let zone = handleZone(forBlockWidth: blockWidth)
        let isSelected = entry.id == appState.selectedSegmentID
        let baseFill = entry.index.isMultiple(of: 2) ? Color.gray.opacity(0.24) : Color.gray.opacity(0.36)
        let fill = isSelected ? Color.accentColor.opacity(0.85) : baseFill

        // A grip lights up when the cue is selected or that handle is being
        // hovered / dragged.
        let hoveredZone = hoverTarget?.id == entry.id ? hoverTarget?.zone : nil
        let draggedKind = activeDrag?.id == entry.id ? activeDrag?.kind : nil
        let startLit = isSelected || hoveredZone == .startHandle || draggedKind == .resizeStart
        let endLit = isSelected || hoveredZone == .endHandle || draggedKind == .resizeEnd
        let showGrips = blockWidth >= gripMinBlockWidth
        // Keep the label clear of the grips (and the grab zones); drop it
        // when there is no room left for a readable stub.
        let labelRoom = blockWidth - 2 * zone
        let showLabel = labelRoom >= 12

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 1.5 : 0.5)
                )

            // Grip handles mark the resize-grab zones. A grip is drawn only
            // at a cue's true edge, not where the window clips the block.
            if showGrips {
                HStack(spacing: 0) {
                    gripView(lit: startLit, blocksHeight: blocksHeight)
                        .opacity(block.hasStartEdge ? 1 : 0)
                    Spacer(minLength: 0)
                    gripView(lit: endLit, blocksHeight: blocksHeight)
                        .opacity(block.hasEndEdge ? 1 : 0)
                }
                .padding(.horizontal, gripInset)
                .allowsHitTesting(false)
            }

            if showLabel {
                Text(EmphasisMarkup.strip(seg.text))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .padding(.horizontal, zone)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: blockWidth, height: blocksHeight)
        .contentShape(Rectangle())
        // Hover is attached before `.offset` so `.local` is the block's own
        // space: x == 0 is the block's visible left edge.
        .onContinuousHover(coordinateSpace: .local) { phase in
            updateHover(phase, entryID: entry.id, block: block)
        }
        .offset(x: block.xStart, y: blocksTop)
        .highPriorityGesture(
            dragGesture(entry: entry, block: block, windowStart: windowStart, width: width)
        )
    }

    private func gripView(lit: Bool, blocksHeight: CGFloat) -> some View {
        Capsule()
            .fill(Color.white.opacity(lit ? 0.9 : 0.55))
            .frame(width: gripWidth, height: blocksHeight * gripHeightFraction)
    }

    /// A block's on-screen geometry within the canvas: the raw (possibly
    /// off-window) edge positions, plus the clipped visible frame.
    private struct BlockGeometry {
        let rawXStart: CGFloat
        let rawXEnd: CGFloat
        let canvasWidth: CGFloat

        var xStart: CGFloat { max(rawXStart, 0) }
        var xEnd: CGFloat { min(rawXEnd, canvasWidth) }
        /// Visible width (never thinner than 3 pt, so tiny cues stay grabbable).
        var width: CGFloat { max(xEnd - xStart, 3) }
        /// False when the window clips the cue's start / end off-screen; the
        /// clipped side is then just the window boundary, not a resize handle.
        var hasStartEdge: Bool { rawXStart >= 0 }
        var hasEndEdge: Bool { rawXEnd <= canvasWidth }
    }

    /// Classifies a point (x in the block's visible-frame space) as one of
    /// the two handle zones or the middle move zone. When a narrow block's
    /// zones overlap, the nearer edge wins.
    private func blockZone(atLocalX x: CGFloat, block: BlockGeometry) -> BlockZone {
        let w = block.width
        let hz = handleZone(forBlockWidth: w)
        let inStart = block.hasStartEdge && x <= hz
        let inEnd = block.hasEndEdge && x >= w - hz
        switch (inStart, inEnd) {
        case (true, true): return x <= w / 2 ? .startHandle : .endHandle
        case (true, false): return .startHandle
        case (false, true): return .endHandle
        case (false, false): return .middle
        }
    }

    private func dragKind(for zone: BlockZone) -> DragKind {
        switch zone {
        case .startHandle: return .resizeStart
        case .endHandle: return .resizeEnd
        case .middle: return .move
        }
    }

    // MARK: - Cursor

    private func cursor(for zone: BlockZone) -> NSCursor {
        zone == .middle ? .openHand : .resizeLeftRight
    }

    private func dragCursor(for kind: DragKind) -> NSCursor {
        kind == .move ? .closedHand : .resizeLeftRight
    }

    /// Uses `set()` only (never push/pop), so there is nothing to unbalance
    /// if a hover-ended event is dropped or reordered.
    private func updateHover(_ phase: HoverPhase, entryID: UUID, block: BlockGeometry) {
        switch phase {
        case .active(let point):
            if let drag = activeDrag {
                // Mid-drag: keep the drag cursor, leave hover state alone.
                dragCursor(for: drag.kind).set()
                return
            }
            let zone = blockZone(atLocalX: point.x, block: block)
            let target = HoverTarget(id: entryID, zone: zone)
            if hoverTarget != target { hoverTarget = target }
            cursor(for: zone).set()
        case .ended:
            if hoverTarget?.id == entryID { hoverTarget = nil }
            if activeDrag == nil { NSCursor.arrow.set() }
        }
    }

    // MARK: - Drag

    private func dragGesture(entry: Entry, block: BlockGeometry, windowStart: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                if activeDrag == nil || activeDrag?.id != entry.id {
                    let pxPerSec = pixelsPerSecond(width: width)
                    let kind = dragKind(for: blockZone(atLocalX: value.startLocation.x - block.xStart, block: block))
                    var grabOffset: CGFloat = 0
                    switch kind {
                    case .resizeStart: grabOffset = value.startLocation.x - block.rawXStart
                    case .resizeEnd: grabOffset = value.startLocation.x - block.rawXEnd
                    case .move: break
                    }
                    activeDrag = ActiveDrag(
                        id: entry.id,
                        kind: kind,
                        windowStart: windowStart,
                        pixelsPerSecond: pxPerSec,
                        grabOffset: grabOffset
                    )
                }
                guard var drag = activeDrag, drag.id == entry.id else { return }
                dragCursor(for: drag.kind).set()
                switch drag.kind {
                case .move:
                    let deltaPixels = value.translation.width - drag.lastTranslationWidth
                    if deltaPixels != 0 {
                        appState.moveSegment(entry.id, by: Double(deltaPixels / drag.pixelsPerSecond))
                    }
                    drag.lastTranslationWidth = value.translation.width
                    activeDrag = drag
                case .resizeStart:
                    let t = drag.windowStart + Double((value.location.x - drag.grabOffset) / drag.pixelsPerSecond)
                    appState.setStart(entry.id, to: t)
                case .resizeEnd:
                    let t = drag.windowStart + Double((value.location.x - drag.grabOffset) / drag.pixelsPerSecond)
                    appState.setEnd(entry.id, to: t)
                }
            }
            .onEnded { value in
                let distance = max(abs(value.translation.width), abs(value.translation.height))
                if distance < 3 {
                    appState.selectSegment(entry.id)
                }
                activeDrag = nil
                hoverTarget = nil
                NSCursor.arrow.set()
            }
    }

    // MARK: - Drag readout

    /// The value being edited, formatted m:ss.t, and the script time the
    /// readout is anchored to.
    private func dragReadoutInfo() -> (text: String, anchorTime: Double)? {
        guard let drag = activeDrag,
              let seg = appState.project.script.segments.first(where: { $0.id == drag.id })
        else { return nil }
        switch drag.kind {
        case .resizeStart:
            return (formatTime(seg.start), seg.start)
        case .resizeEnd:
            return (formatTime(seg.end), seg.end)
        case .move:
            return ("\(formatTime(seg.start)) \u{2192} \(formatTime(seg.end))", (seg.start + seg.end) / 2)
        }
    }

    /// A small dark capsule in the band just above the blocks, centered on
    /// the edited edge (or the cue, for a move) and clamped to the canvas.
    @ViewBuilder
    private func dragReadout(windowStart: Double, width: CGFloat) -> some View {
        if let info = dragReadoutInfo() {
            ClampedCenterLayout(centerX: timeToX(info.anchorTime, windowStart: windowStart, width: width)) {
                Text(info.text)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 7)
                    .frame(height: rulerHeight)
                    .background(Capsule().fill(Color.black.opacity(0.8)))
            }
            .frame(width: width, height: rulerHeight)
            .allowsHitTesting(false)
        }
    }

    /// Places its single subview at its ideal size, horizontally centered on
    /// `centerX` but clamped to stay fully inside the container.
    private struct ClampedCenterLayout: Layout {
        var centerX: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions(by: subviews.first?.sizeThatFits(.unspecified) ?? .zero)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard let sub = subviews.first else { return }
            let size = sub.sizeThatFits(.unspecified)
            let x = min(max(centerX - size.width / 2, 0), max(bounds.width - size.width, 0))
            sub.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY), anchor: .topLeading, proposal: .unspecified)
        }
    }

    // MARK: - Audio waveform track

    /// The project audio's peak envelope, time-aligned with the cue blocks —
    /// speech energy under the blocks makes boundary adjustments obvious.
    private func waveformLane(wave: AudioWaveform, windowStart: Double, width: CGFloat) -> some View {
        Canvas { context, size in
            let pps = width / CGFloat(windowSpan)
            guard pps > 0 else { return }
            let mid = size.height / 2
            let step: CGFloat = 2
            var bars = Path()
            var x: CGFloat = 0
            while x < size.width {
                let t0 = windowStart + Double(x / pps)
                let t1 = windowStart + Double((x + step) / pps)
                let peak = CGFloat(wave.peak(from: t0, to: t1))
                if peak > 0 {
                    let h = max(1.5, peak * (size.height - 4))
                    bars.addRect(CGRect(x: x, y: mid - h / 2, width: step * 0.7, height: h))
                }
                x += step
            }
            context.fill(bars, with: .color(.green.opacity(0.5)))
            var separator = Path()
            separator.move(to: CGPoint(x: 0, y: 0.5))
            separator.addLine(to: CGPoint(x: size.width, y: 0.5))
            context.stroke(separator, with: .color(.secondary.opacity(0.25)), lineWidth: 1)
        }
    }

    // MARK: - Playhead

    private func playheadLine(windowStart: Double, width: CGFloat, height: CGFloat) -> some View {
        let scriptTime = appState.playheadVideoTime - appState.project.style.leadIn
        let x = timeToX(scriptTime, windowStart: windowStart, width: width)
        return Rectangle()
            .fill(Color.red.opacity(0.85))
            .frame(width: 1.5, height: height)
            .offset(x: x - 0.75, y: 0)
    }

    // MARK: - Window / time-space conversion

    /// Script-time window start: centered on the playhead while idle, but
    /// frozen to the value captured at drag-start for the duration of a drag
    /// so the strip doesn't shift underneath the user's cursor.
    private var effectiveWindowStart: Double {
        activeDrag?.windowStart ?? liveWindowStart
    }

    private var liveWindowStart: Double {
        playheadScriptTime - windowSpan / 2
    }

    private var playheadScriptTime: Double {
        appState.playheadVideoTime - appState.project.style.leadIn
    }

    private func pixelsPerSecond(width: CGFloat) -> CGFloat {
        guard windowSpan > 0 else { return 1 }
        return width / CGFloat(windowSpan)
    }

    private func timeToX(_ t: Double, windowStart: Double, width: CGFloat) -> CGFloat {
        CGFloat(t - windowStart) * pixelsPerSecond(width: width)
    }

    private func xToTime(_ x: CGFloat, windowStart: Double, width: CGFloat) -> Double {
        windowStart + Double(x / pixelsPerSecond(width: width))
    }
}
