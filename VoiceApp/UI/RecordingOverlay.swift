import SwiftUI
import AppKit

struct RecordingOverlayView: View {
    let appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: OverlayPhase = .hidden
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let isVisible = phase != .hidden
        let motion = overlayMotionState(isVisible: isVisible, reduceMotion: reduceMotion)

        overlayContent {
            ZStack {
                switch phase {
                case .hidden:
                    Color.clear
                case .recording:
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundColor(.white)
                            .opacity(microphoneOpacity(audioLevel: appState.audioLevel))
                            .shadow(color: .white.opacity(0.28), radius: 5)

                        WaveformView(audioLevel: appState.audioLevel)
                            .frame(width: 42, height: 18)
                    }
                    .transition(contentTransition)
                case .processing:
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.small)
                        .tint(.white)
                        .transition(contentTransition)
                case .success:
                    Image(systemName: "checkmark")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .transition(contentTransition)
                case .failure:
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundColor(Color(red: 1, green: 0.78, blue: 0.38))
                        .transition(contentTransition)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.18), value: phase)
        }
        .scaleEffect(x: motion.horizontalScale, y: motion.verticalScale, anchor: .center)
        .opacity(motion.opacity)
        .blur(radius: motion.blurRadius)
        .animation(revealAnimation(isVisible: isVisible), value: isVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
    }

    private var contentTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.88)),
                removal: .opacity
            )
    }

    private func revealAnimation(isVisible: Bool) -> Animation {
        if reduceMotion {
            return .easeOut(duration: 0.14)
        }
        return isVisible
            ? .spring(response: 0.44, dampingFraction: 0.86, blendDuration: 0.04)
            : .easeIn(duration: 0.2)
    }

    @ViewBuilder
    private func overlayContent<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        content()
            .frame(width: 122, height: 58)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.2, green: 0.7, blue: 0.8),
                        Color(red: 0.0, green: 0.2, blue: 0.5)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(0.26), lineWidth: 0.8)
            )
            .shadow(color: Color(red: 0.02, green: 0.16, blue: 0.36).opacity(0.32), radius: 16, y: 8)
            .shadow(color: Color(red: 0.18, green: 0.72, blue: 0.88).opacity(0.16), radius: 8, y: 2)
    }
}

struct WaveformView: View {
    let audioLevel: Double
    let shouldReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    @State private var recentLevels = Array(repeating: 0.0, count: 5)

    var body: some View {
        let barScales = waveformBarScales(recentLevels: recentLevels)

        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .frame(width: 3, height: 18)
                    .foregroundColor(.white.opacity(0.8))
                    .scaleEffect(y: barScales[index], anchor: .center)
            }
        }
        .animation(shouldReduceMotion ? nil : .easeOut(duration: 0.01), value: recentLevels)
        .onAppear {
            recentLevels[0] = audioLevel
        }
        .onChange(of: audioLevel) { _, newLevel in
            if newLevel < 0.01 {
                recentLevels = Array(repeating: 0, count: 5)
            } else {
                recentLevels.insert(newLevel, at: 0)
                recentLevels.removeLast()
            }
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

        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        self.panel = NSPanel(contentRect: recordingOverlayPanelFrame(in: screen.visibleFrame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false

        hostingView.topAnchor.constraint(equalTo: panel.contentView!.topAnchor).isActive = true
        hostingView.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor).isActive = true
        hostingView.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor).isActive = true
        hostingView.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor).isActive = true

        panel.setFrameAutosaveName("RecordingOverlay")
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        let screen = NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
        panel.setFrame(recordingOverlayPanelFrame(in: screen.visibleFrame), display: true)
    }
}
