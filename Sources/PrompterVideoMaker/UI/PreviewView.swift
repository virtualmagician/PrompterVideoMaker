import SwiftUI

/// WYSIWYG 16:9 preview. Renders exactly what export would produce by asking
/// `PrompterComposition` for a raster frame at the current video time —
/// there is no separate "preview renderer".
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState

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
        .clipped()
        .shadow(color: .black.opacity(0.4), radius: 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .contentShape(Rectangle())
        .onTapGesture { appState.togglePlay() }
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
