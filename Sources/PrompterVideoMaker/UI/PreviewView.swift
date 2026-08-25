import SwiftUI

/// WYSIWYG 16:9 preview. Renders exactly what export would produce by asking
/// `PrompterComposition` for a raster frame at the current video time —
/// there is no separate "preview renderer".
struct PreviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GeometryReader { geo in
            let size = fittedSize(in: geo.size)
            ZStack {
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
                        .frame(width: size.width, height: size.height)
                        .onChange(of: context.date) { _, newDate in
                            appState.tick(date: newDate)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .clipped()
                    .shadow(color: .black.opacity(0.4), radius: 24)
                } else {
                    emptyHint
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { appState.togglePlay() }
        }
        .background(Color.black)
    }

    private func fittedSize(in container: CGSize) -> CGSize {
        guard container.width > 0, container.height > 0 else { return .zero }
        let aspect: CGFloat = StyleSettings.canvasWidth / StyleSettings.canvasHeight
        var w = container.width
        var h = w / aspect
        if h > container.height {
            h = container.height
            w = h * aspect
        }
        return CGSize(width: max(w, 1), height: max(h, 1))
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
