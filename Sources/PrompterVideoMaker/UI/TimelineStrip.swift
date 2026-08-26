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
    }

    @State private var activeDrag: ActiveDrag?

    private let edgeHitWidth: CGFloat = 7
    private let rulerHeight: CGFloat = 14
    private let stripHeight: CGFloat = 64

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
        let blocksHeight = max(height - rulerHeight, 0)

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

            playheadLine(windowStart: windowStart, width: width, height: height)
                .allowsHitTesting(false)
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
        let rawXStart = timeToX(seg.start, windowStart: windowStart, width: width)
        let rawXEnd = timeToX(seg.end, windowStart: windowStart, width: width)
        let xStart = max(rawXStart, 0)
        let xEnd = min(rawXEnd, width)
        let blockWidth = max(xEnd - xStart, 3)
        let isSelected = entry.id == appState.selectedSegmentID
        let baseFill = entry.index.isMultiple(of: 2) ? Color.gray.opacity(0.24) : Color.gray.opacity(0.36)
        let fill = isSelected ? Color.accentColor.opacity(0.85) : baseFill

        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 1.5 : 0.5)
                )

            // Brighter edge caps hint at the ~7pt resize-grab zone.
            if blockWidth > 16 {
                HStack {
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 3, height: blocksHeight * 0.55)
                    Spacer(minLength: 0)
                    Capsule()
                        .fill(Color.white.opacity(0.55))
                        .frame(width: 3, height: blocksHeight * 0.55)
                }
                .padding(.horizontal, 2)
            }

            if blockWidth > 22 {
                Text(EmphasisMarkup.strip(seg.text))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
                    .padding(.horizontal, 6)
            }
        }
        .frame(width: blockWidth, height: blocksHeight)
        .offset(x: xStart, y: blocksTop)
        .contentShape(Rectangle())
        .highPriorityGesture(
            dragGesture(entry: entry, rawXStart: rawXStart, rawXEnd: rawXEnd, windowStart: windowStart, width: width)
        )
    }

    private func dragGesture(entry: Entry, rawXStart: CGFloat, rawXEnd: CGFloat, windowStart: Double, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                if activeDrag == nil || activeDrag?.id != entry.id {
                    let pxPerSec = pixelsPerSecond(width: width)
                    let distStart = abs(value.startLocation.x - rawXStart)
                    let distEnd = abs(value.startLocation.x - rawXEnd)
                    let kind: DragKind
                    if distStart <= edgeHitWidth && distStart <= distEnd {
                        kind = .resizeStart
                    } else if distEnd <= edgeHitWidth {
                        kind = .resizeEnd
                    } else {
                        kind = .move
                    }
                    activeDrag = ActiveDrag(id: entry.id, kind: kind, windowStart: windowStart, pixelsPerSecond: pxPerSec)
                }
                guard var drag = activeDrag, drag.id == entry.id else { return }
                switch drag.kind {
                case .move:
                    let deltaPixels = value.translation.width - drag.lastTranslationWidth
                    if deltaPixels != 0 {
                        appState.moveSegment(entry.id, by: Double(deltaPixels / drag.pixelsPerSecond))
                    }
                    drag.lastTranslationWidth = value.translation.width
                    activeDrag = drag
                case .resizeStart:
                    let t = drag.windowStart + Double(value.location.x / drag.pixelsPerSecond)
                    appState.setStart(entry.id, to: t)
                case .resizeEnd:
                    let t = drag.windowStart + Double(value.location.x / drag.pixelsPerSecond)
                    appState.setEnd(entry.id, to: t)
                }
            }
            .onEnded { value in
                let distance = max(abs(value.translation.width), abs(value.translation.height))
                if distance < 3 {
                    appState.selectSegment(entry.id)
                }
                activeDrag = nil
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
