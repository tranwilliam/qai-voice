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
                    VStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.white)
                        WaveformView()
                            .frame(width: 40, height: 16)
                    }
                    .padding(12)
                }
            case .processing:
                overlayContent {
                    ProgressView()
                        .scaleEffect(1.2, anchor: .center)
                        .padding(12)
                }
            case .success:
                overlayContent {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.green)
                        .padding(12)
                }
                .transition(.opacity)
            case .failure:
                overlayContent {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                        .padding(12)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .position(x: 150, y: 35)
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
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.2, green: 0.7, blue: 0.8),  // Teal
                        Color(red: 0.0, green: 0.2, blue: 0.5)   // Dark blue
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .opacity(0.9)
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

        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 70), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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
        let visibleFrame = screen.visibleFrame

        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 70
        let topMargin: CGFloat = 50

        let x = (visibleFrame.midX - panelWidth / 2).rounded()
        let y = (visibleFrame.maxY - topMargin - panelHeight).rounded()

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}
