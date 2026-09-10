import SwiftUI
import AppKit

struct RecordingOverlayView: View {
    let appState: AppState
    @State private var phase: OverlayPhase = .hidden
    @State private var previousState: DictationState = .idle
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        Group {
            switch phase {
            case .hidden:
                EmptyView()
            case .recording:
                overlayContent {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Listening")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.white)
                            WaveformView()
                                .frame(height: 20)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            case .processing(let label):
                overlayContent {
                    HStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(0.8, anchor: .center)
                        Text(label)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            case .success:
                overlayContent {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.green)
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .transition(.opacity)
            case .failure(let message):
                overlayContent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.orange)
                            Text("Transcript saved")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: appState.state) { oldState, newState in
            hideTask?.cancel()
            let newPhase = overlayPhase(previous: oldState, current: newState, lastError: appState.lastError)
            phase = newPhase

            if newPhase == .success {
                hideTask = Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    if !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            phase = .hidden
                        }
                    }
                }
            } else if case .failure = newPhase {
                hideTask = Task {
                    try? await Task.sleep(for: .milliseconds(2500))
                    if !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            phase = .hidden
                        }
                    }
                }
            }
            previousState = oldState
        }
    }

    @ViewBuilder
    private func overlayContent<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        content()
            .background(.regularMaterial)
            .cornerRadius(12)
            .shadow(radius: 8)
            .padding(16)
    }
}

struct WaveformView: View {
    @State private var scale: [CGFloat] = [1, 0.8, 1, 0.6, 1]
    let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .frame(width: 3, height: 16 * scale[index])
                    .foregroundColor(.white.opacity(0.8))
                    .scaleEffect(y: scale[index], anchor: .center)
            }
        }
        .onAppear {
            if !shouldReduceMotion {
                startAnimation()
            }
        }
    }

    private func startAnimation() {
        let animation = Animation.easeInOut(duration: 0.6).repeatForever(autoreverses: true)
        withAnimation(animation) {
            scale = [0.6, 1, 0.8, 1, 0.7]
        }
    }
}

@MainActor
final class RecordingOverlayController {
    private weak var appState: AppState?
    private let panel: NSPanel

    init(appState: AppState) {
        self.appState = appState

        let contentView = RecordingOverlayView(appState: appState)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        self.panel = NSPanel()
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView

        panel.setFrameAutosaveName("RecordingOverlay")
        positionPanel()
    }

    private func positionPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        let visibleFrame = screen.visibleFrame

        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 70
        let topMargin: CGFloat = 50

        let x = (visibleFrame.midX - panelWidth / 2).rounded()
        let y = (visibleFrame.maxY - topMargin - panelHeight).rounded()

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}
