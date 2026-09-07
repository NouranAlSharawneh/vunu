import SwiftUI

/// 10 bars driven by the mic level; per-bar smoothing with a left→right phase offset so it "flows".
struct WaveformView: View {
    var level: Float          // 0…1
    var active: Bool
    var color: Color = Tokens.cream
    var barWidth: CGFloat = 2.8
    var pitch: CGFloat = 5.3
    var minHeight: CGFloat = 2.8
    var maxHeight: CGFloat = 18

    @State private var heights: [CGFloat] = Array(repeating: 2.8, count: 10)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !active)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                let totalW = pitch * CGFloat(heights.count - 1) + barWidth
                let x0 = (size.width - totalW) / 2
                for (i, h) in heights.enumerated() {
                    let rect = CGRect(x: x0 + CGFloat(i) * pitch, y: (size.height - h) / 2, width: barWidth, height: h)
                    g.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color))
                }
            }
            .onChange(of: t) { _, _ in tick(t) }
        }
        .frame(width: pitch * 9 + barWidth + 2, height: maxHeight + 2)
    }

    private func tick(_ t: TimeInterval) {
        var next = heights
        let base = CGFloat(active ? level : 0)
        for i in 0..<next.count {
            let phase = sin(t * 9 + Double(i) * 0.7) * 0.25 + 0.75
            let centerWeight = 1 - abs(CGFloat(i) - 4.5) / 6
            let target = active ? max(minHeight, minHeight + (maxHeight - minHeight) * base * CGFloat(phase) * (0.55 + 0.45 * centerWeight)) : minHeight
            // attack fast (30 ms ≈ 2 frames), release slower (120 ms ≈ 7 frames)
            let k: CGFloat = target > next[i] ? 0.55 : 0.2
            next[i] += (target - next[i]) * k
        }
        heights = next
    }
}

/// 3-dot breathing loader for the processing state.
struct BreathingDots: View {
    var color: Color = Tokens.cream
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let s = 0.6 + 0.4 * (sin(t * 4 + Double(i) * 0.9) + 1) / 2
                    Circle().fill(color).frame(width: 6, height: 6).scaleEffect(s).opacity(0.5 + s * 0.5)
                }
            }
        }
    }
}
