import SwiftUI
import AppKit

/// The pill. Idle: flat dots. Recording: app icon + cancel + waveform + confirm/stop. Processing: breathing dots.
struct FlowBarView: View {
    @Bindable var session: SessionCoordinator
    var onCancel: () -> Void
    var onConfirm: () -> Void
    var onClickIdle: () -> Void
    var showLanguage: Bool
    var languages: [String]
    var onPickLanguage: (String) -> Void

    @State private var shake: CGFloat = 0
    @State private var flash = false
    @State private var hovering = false

    private var isRecording: Bool { session.state == .recording || session.state == .armed }
    private var isProcessing: Bool { session.state.isProcessing }
    private var isError: Bool { session.state.isError }

    var body: some View {
        VStack(spacing: 6) {
            if isProcessing && session.takingLonger { banner("Taking longer than usual") }
            if !session.previewText.isEmpty && isRecording { preview }
            pill
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .fixedSize()
        .onChange(of: session.state) { old, new in
            if new.isError { withAnimation(.default) { shakeBar() } }
            if old == .inserting && new == .idle { flashSuccess() }
        }
    }

    private var pill: some View {
        ZStack {
            Capsule().fill(Tokens.ink.opacity(0.92))
            Capsule().strokeBorder(Tokens.barBorder, lineWidth: 1)
            HStack(spacing: 8) {
                if isRecording || isProcessing {
                    if let icon = session.target?.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 18, height: 18).clipShape(RoundedRectangle(cornerRadius: 4))
                            .transition(.scale.combined(with: .opacity))
                    }
                    if isRecording {
                        circleButton(fill: Tokens.greyDark) { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white) }
                            .onTapGesture(perform: onCancel)
                            .help("Cancel (Esc)")
                    }
                }
                if isProcessing {
                    BreathingDots().frame(width: 40, height: 20)
                } else if isError, case .error(let msg) = session.state, msg != "no audio" {
                    Text(msg).font(Fonts.ui(11, weight: .medium)).foregroundStyle(Tokens.orange).lineLimit(1).frame(minWidth: 60)
                } else {
                    WaveformView(level: session.audio.level, active: isRecording, color: flash ? Tokens.deepGreen : Tokens.cream)
                        .allowsHitTesting(false)
                }
                if isRecording {
                    circleButton(fill: Tokens.offWhite) {
                        if session.mode == .handsFree { RoundedRectangle(cornerRadius: 1.5).fill(Tokens.ink).frame(width: 8, height: 8) }
                        else { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tokens.ink) }
                    }
                    .onTapGesture(perform: onConfirm)
                    .help(session.mode == .handsFree ? "Stop and insert" : "Insert now")
                }
                if showLanguage && isRecording && languages.count >= 2 && hovering {
                    Menu {
                        ForEach(languages, id: \.self) { l in Button(Locale.current.localizedString(forIdentifier: l) ?? l) { onPickLanguage(l) } }
                    } label: { Text((languages.first ?? "en").prefix(2).uppercased()).font(Fonts.ui(10, weight: .semibold)).foregroundStyle(Tokens.cream) }
                    .menuStyle(.borderlessButton).frame(width: 26)
                }
            }
            .padding(.horizontal, isRecording || isProcessing ? 9 : 12)
        }
        .frame(minWidth: 120, minHeight: isRecording || isProcessing ? 44 : 35, maxHeight: isRecording || isProcessing ? 44 : 35)
        .fixedSize()
        .contentShape(Capsule())
        .onHover { hovering = $0 }
        .onTapGesture { if session.state == .idle { onClickIdle() } }
        .help(session.state == .idle ? "Hold fn to dictate · Mic in use: \(currentMic)" : "")
        .offset(x: shake)
        .animation(.spring(response: 0.18, dampingFraction: 0.85), value: isRecording)
        .animation(.spring(response: 0.18, dampingFraction: 0.85), value: isProcessing)
    }

    private var currentMic: String {
        if let uid = Preferences.shared.preferredMicrophoneUID, let d = AudioDevices.device(withUID: uid) { return d.name }
        return AudioDevices.inputDevices().first?.name ?? "Default"
    }

    private func circleButton<C: View>(fill: Color, @ViewBuilder content: () -> C) -> some View {
        ZStack { Circle().fill(fill); content() }.frame(width: 22, height: 22).contentShape(Circle())
    }

    private func banner(_ text: String) -> some View {
        Text(text).font(Fonts.ui(11, weight: .medium)).foregroundStyle(Tokens.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(Tokens.offWhite))
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var preview: some View {
        Text(session.previewText).font(Fonts.ui(12)).foregroundStyle(Tokens.cream).lineLimit(2).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 6).frame(maxWidth: 360)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tokens.ink.opacity(0.92)))
    }

    private func shakeBar() {
        Task { @MainActor in
            for dx in [4, -4, 4, -4, 3, -3, 0] as [CGFloat] { withAnimation(.linear(duration: 0.04)) { shake = dx }; try? await Task.sleep(for: .milliseconds(40)) }
        }
    }
    private func flashSuccess() {
        flash = true
        Task { @MainActor in try? await Task.sleep(for: .milliseconds(120)); flash = false }
    }
}
