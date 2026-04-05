import SwiftUI

/// Determines flame intensity tier based on qualified visit count.
enum FlameIntensity {
    case none
    case warm      // 5–9 visits: subtle single flame
    case hot       // 10–19 visits: moderate double flame
    case blazing   // 20+ visits: intense triple flame

    init(visitCount: Int) {
        switch visitCount {
        case 20...: self = .blazing
        case 10...: self = .hot
        case 5...:  self = .warm
        default:    self = .none
        }
    }

    var flameCount: Int {
        switch self {
        case .none:    return 0
        case .warm:    return 1
        case .hot:     return 2
        case .blazing: return 3
        }
    }

    var glowColor: Color {
        switch self {
        case .none:    return .clear
        case .warm:    return .orange
        case .hot:     return .orange
        case .blazing: return .red
        }
    }

    var label: String {
        switch self {
        case .none:    return ""
        case .warm:    return "Warm"
        case .hot:     return "Hot"
        case .blazing: return "Blazing"
        }
    }
}

/// An animated flame effect that wraps around a map annotation or list icon.
struct FlameEffectView: View {
    let intensity: FlameIntensity

    @State private var phase: CGFloat = 0

    var body: some View {
        if intensity != .none {
            ZStack {
                ForEach(0..<intensity.flameCount, id: \.self) { index in
                    FlameParticle(
                        phase: phase,
                        index: index,
                        intensity: intensity
                    )
                }
            }
            .onAppear {
                withAnimation(
                    .easeInOut(duration: 1.2)
                    .repeatForever(autoreverses: true)
                ) {
                    phase = 1
                }
            }
        }
    }
}

/// A single animated flame particle.
private struct FlameParticle: View {
    let phase: CGFloat
    let index: Int
    let intensity: FlameIntensity

    private var offsetAngle: Double {
        switch index {
        case 0: return -0.3   // left-ish
        case 1: return 0.3    // right-ish
        case 2: return 0.0    // center
        default: return 0.0
        }
    }

    private var baseOffsetY: CGFloat {
        switch index {
        case 0: return -18
        case 1: return -18
        case 2: return -22
        default: return -18
        }
    }

    var body: some View {
        Text("🔥")
            .font(.system(size: flameSize))
            .offset(
                x: CGFloat(sin(offsetAngle * .pi)) * 8,
                y: baseOffsetY + (phase * flickerRange)
            )
            .opacity(0.7 + phase * 0.3)
            .scaleEffect(0.9 + phase * 0.15)
            .animation(
                .easeInOut(duration: duration)
                .repeatForever(autoreverses: true)
                .delay(delay),
                value: phase
            )
    }

    private var flameSize: CGFloat {
        switch intensity {
        case .none:    return 0
        case .warm:    return 16
        case .hot:     return 14
        case .blazing: return index == 2 ? 16 : 13
        }
    }

    private var flickerRange: CGFloat {
        switch index {
        case 0: return -3
        case 1: return -2
        case 2: return -4
        default: return -3
        }
    }

    private var duration: Double {
        switch index {
        case 0: return 0.8
        case 1: return 1.0
        case 2: return 0.6
        default: return 0.8
        }
    }

    private var delay: Double {
        Double(index) * 0.15
    }
}

/// A small inline flame badge for list rows, showing a colored flame icon with intensity label.
struct FlameIndicatorView: View {
    let intensity: FlameIntensity

    var body: some View {
        if intensity != .none {
            HStack(spacing: 2) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                    .foregroundStyle(intensity.glowColor)

                Text(intensity.label)
                    .font(.caption2.bold())
                    .foregroundStyle(intensity.glowColor)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(intensity.glowColor.opacity(0.12))
            .clipShape(Capsule())
        }
    }
}
