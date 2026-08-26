import SwiftUI

/// WYSIWYG 16:9 preview. Renders exactly what export would produce by asking
/// `PrompterComposition` for a raster frame at the current video time —
/// there is no separate "preview renderer".
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState

    /// Size of the aspect-locked preview box, used to convert view points
    /// into canvas (1920x1080) coordinates for hit-testing and to scale the
    /// selection overlay back down into view space.
    @State private var boxSize: CGSize = .zero

    // Per-gesture scratch state (reset on each new drag).
    @State private var dragIsActive = false
    @State private var dragWasPlayingAtStart = false
    @State private var dragHadSelectionAtStart = false
    @State private var dragHitWord = false

    var body: some View {
        // The visible pane is locked to the video's exact 16:9 aspect, so
        // what you see is precisely the exported frame — no extra background
        // beyond the video bounds.
        Group {
            if appState.composition != nil {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !appState.isPlaying)) { context in
                    let time = appState.currentDisplayTime(at: context.date)
                    Canvas { ctx, canvasSize in
                        guard canvasSize.width > 0,
                              let cg = appState.composition?.image(
                                atVideoTime: time,
                                scale: canvasSize.width / StyleSettings.canvasWidth
                              ) else { return }
                        ctx.draw(
                            Image(decorative: cg, scale: 1, orientation: .up),
                            in: CGRect(origin: .zero, size: canvasSize)
                        )
                    }
                    .onChange(of: context.date) { _, newDate in
                        appState.tick(date: newDate)
                    }
                }
            } else {
                emptyHint
            }
        }
        .aspectRatio(StyleSettings.canvasWidth / StyleSettings.canvasHeight, contentMode: .fit)
        .background(Color.black)
        .background(ScrollWheelCatcher { ribbonDelta in
            appState.scrubByRibbonPixels(ribbonDelta)
        })
        .overlay(selectionHighlightOverlay)
        .overlay(alignment: .top) { formatBar }
        .clipped()
        .shadow(color: .black.opacity(0.4), radius: 24)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { boxSize = $0 }
        .gesture(previewDragGesture)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
    }

    // MARK: - Click / drag word selection

    /// Converts a point in the preview box's own coordinate space into
    /// canvas (1920x1080, top-down) coordinates.
    private func canvasPoint(from viewPoint: CGPoint) -> CGPoint? {
        guard boxSize.width > 0 else { return nil }
        let scale = StyleSettings.canvasWidth / boxSize.width
        return CGPoint(x: viewPoint.x * scale, y: viewPoint.y * scale)
    }

    private var previewDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragIsActive {
                    // Gesture start.
                    dragIsActive = true
                    dragWasPlayingAtStart = appState.isPlaying
                    dragHadSelectionAtStart = appState.wordSelection != nil
                    dragHitWord = false
                    guard !dragWasPlayingAtStart else { return }
                    if let point = canvasPoint(from: value.location) {
                        dragHitWord = appState.previewClick(canvasPoint: point, extend: false)
                    }
                } else {
                    guard !dragWasPlayingAtStart else { return }
                    if let point = canvasPoint(from: value.location) {
                        if appState.previewClick(canvasPoint: point, extend: true) {
                            dragHitWord = true
                        }
                    }
                }
            }
            .onEnded { value in
                defer { dragIsActive = false }
                let movement = hypot(value.translation.width, value.translation.height)
                let isTap = movement < 4

                if dragWasPlayingAtStart {
                    if isTap { appState.pause() }
                    return
                }

                guard !dragHitWord, isTap else { return }
                if dragHadSelectionAtStart {
                    // Click-away deselects; the *next* empty click toggles play.
                    appState.clearWordSelection()
                } else {
                    appState.togglePlay()
                }
            }
    }

    /// Highlight boxes for the current word selection, drawn in view space
    /// by scaling the canvas-space rects down to the preview box's size.
    private var selectionHighlightOverlay: some View {
        let scale = boxSize.width > 0 ? boxSize.width / StyleSettings.canvasWidth : 0
        return ZStack(alignment: .topLeading) {
            if scale > 0 {
                ForEach(Array(appState.selectionHighlightRects.enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 6 * scale)
                        .fill(Color.accentColor.opacity(0.28))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6 * scale)
                                .stroke(Color.accentColor, lineWidth: 1.5)
                        )
                        .frame(width: rect.width * scale, height: rect.height * scale)
                        .position(x: (rect.minX + rect.width / 2) * scale, y: (rect.minY + rect.height / 2) * scale)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Small floating Bold / Italic / Underline bar, shown while a word
    /// selection is active.
    @ViewBuilder
    private var formatBar: some View {
        if appState.wordSelection != nil {
            HStack(spacing: 10) {
                Button {
                    appState.toggleFormat(.bold)
                } label: {
                    Text("B").font(.system(size: 13, weight: .bold))
                }
                .keyboardShortcut("b", modifiers: .command)
                .help("Bold (⌘B)")

                Button {
                    appState.toggleFormat(.italic)
                } label: {
                    Text("I").font(.system(size: 13, weight: .semibold)).italic()
                }
                .keyboardShortcut("i", modifiers: .command)
                .help("Italic (⌘I)")

                Button {
                    appState.toggleFormat(.underline)
                } label: {
                    Text("U").font(.system(size: 13, weight: .semibold)).underline()
                }
                .keyboardShortcut("u", modifiers: .command)
                .help("Underline (⌘U)")

                Divider().frame(height: 14)

                Button {
                    appState.clearWordSelection()
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Clear Selection")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 12)
            .transition(.opacity.combined(with: .move(edge: .top)))
            .animation(.easeOut(duration: 0.12), value: appState.wordSelection)
        }
    }

    /// Routes scroll-wheel / trackpad scrolling over the preview into a
    /// callback with the delta converted to ribbon (1920-wide canvas) pixels;
    /// positive = scroll the prompter forward. Uses a local event monitor so
    /// clicks and other gestures pass through untouched.
    private struct ScrollWheelCatcher: NSViewRepresentable {
        let onScroll: (CGFloat) -> Void

        func makeNSView(context: Context) -> MonitorView { MonitorView(onScroll: onScroll) }
        func updateNSView(_ nsView: MonitorView, context: Context) { nsView.onScroll = onScroll }

        final class MonitorView: NSView {
            var onScroll: (CGFloat) -> Void
            private var monitor: Any?

            init(onScroll: @escaping (CGFloat) -> Void) {
                self.onScroll = onScroll
                super.init(frame: .zero)
            }

            @available(*, unavailable)
            required init?(coder: NSCoder) { fatalError("unused") }

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if window != nil, monitor == nil {
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                        guard let self, let window = self.window, event.window === window else { return event }
                        let p = self.convert(event.locationInWindow, from: nil)
                        guard self.bounds.contains(p), self.bounds.width > 1 else { return event }
                        // Line-based wheels report small deltas; scale them up.
                        let raw = event.hasPreciseScrollingDeltas
                            ? event.scrollingDeltaY
                            : event.scrollingDeltaY * 12
                        // Toward end of document = negative deltaY = forward.
                        let ribbonDelta = -raw * (StyleSettings.canvasWidth / self.bounds.width)
                        self.onScroll(ribbonDelta)
                        return nil
                    }
                } else if window == nil, let m = monitor {
                    NSEvent.removeMonitor(m)
                    monitor = nil
                }
            }

            deinit {
                if let m = monitor { NSEvent.removeMonitor(m) }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.below.photo")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.35))
            VStack(spacing: 4) {
                Text("No Script Loaded")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Drop an SRT or audio file here, or use File → Open…")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}
