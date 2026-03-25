import SwiftUI

private let paperBackground = Color(red: 240.0 / 255.0, green: 238.0 / 255.0, blue: 233.0 / 255.0)

struct GlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let strokeOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.28))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color(red: 1.0, green: 0.985, blue: 0.965).opacity(0.22))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(strokeOpacity), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.32, green: 0.24, blue: 0.14).opacity(0.08), radius: 24, x: 0, y: 14)
    }
}

struct SurfaceCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let borderOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color(red: 0.995, green: 0.989, blue: 0.978).opacity(0.96))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(red: 0.40, green: 0.30, blue: 0.20).opacity(borderOpacity), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.32, green: 0.24, blue: 0.14).opacity(0.06), radius: 18, x: 0, y: 10)
    }
}

struct DrawerGlassModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(paperBackground.opacity(0.94))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.24), lineWidth: 1)
                )
                .shadow(color: Color(red: 0.28, green: 0.20, blue: 0.12).opacity(0.04), radius: 16, x: -4, y: 6)
        } else {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.42))
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.34), lineWidth: 1)
                )
                .shadow(color: Color(red: 0.28, green: 0.20, blue: 0.12).opacity(0.04), radius: 18, x: -4, y: 6)
        }
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24, strokeOpacity: Double = 0.40) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, strokeOpacity: strokeOpacity))
    }

    func surfaceCard(cornerRadius: CGFloat = 24, borderOpacity: Double = 0.06) -> some View {
        modifier(SurfaceCardModifier(cornerRadius: cornerRadius, borderOpacity: borderOpacity))
    }

    func drawerGlass(cornerRadius: CGFloat = 28) -> some View {
        modifier(DrawerGlassModifier(cornerRadius: cornerRadius))
    }
}

struct AmbientBackgroundView: View {
    var body: some View {
        ZStack {
            paperBackground

            Circle()
                .fill(Color(red: 0.92, green: 0.80, blue: 0.66).opacity(0.22))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: 320, y: -240)

            Circle()
                .fill(Color(red: 1.0, green: 0.98, blue: 0.95).opacity(0.52))
                .frame(width: 440, height: 440)
                .blur(radius: 64)
                .offset(x: -260, y: 200)
        }
        .ignoresSafeArea()
    }
}

private struct PressFeedbackModifier: ViewModifier {
    let isPressed: Bool
    let pressedScale: CGFloat
    let pressedOpacity: Double
    let pressedYOffset: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed ? pressedScale : 1)
            .opacity(isPressed ? pressedOpacity : 1)
            .offset(y: isPressed ? pressedYOffset : 0)
            .animation(.easeOut(duration: 0.16), value: isPressed)
    }
}

struct GlassCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .modifier(PressFeedbackModifier(isPressed: configuration.isPressed, pressedScale: 0.976, pressedOpacity: 0.93, pressedYOffset: 1.2))
            .glassCard(cornerRadius: 999, strokeOpacity: 0.22)
    }
}

struct FloatingIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(PressFeedbackModifier(isPressed: configuration.isPressed, pressedScale: 0.95, pressedOpacity: 0.90, pressedYOffset: 1.4))
            .background(
                Circle()
                    .fill(Color.white.opacity(0.68))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.44), lineWidth: 1)
            )
            .shadow(color: Color(red: 0.30, green: 0.22, blue: 0.14).opacity(0.08), radius: 10, x: 0, y: 6)
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .foregroundStyle(Color(red: 0.18, green: 0.16, blue: 0.14))
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.42), lineWidth: 1)
            )
            .modifier(PressFeedbackModifier(isPressed: configuration.isPressed, pressedScale: 0.978, pressedOpacity: 0.92, pressedYOffset: 1.0))
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    let enabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(Color.white.opacity(enabled ? 1 : 0.84))
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(enabled ? Color.accentColor.opacity(0.9) : Color.gray.opacity(0.35))
            )
            .shadow(color: enabled ? Color.accentColor.opacity(configuration.isPressed ? 0.10 : 0.18) : .clear, radius: configuration.isPressed ? 6 : 12, x: 0, y: configuration.isPressed ? 4 : 8)
            .modifier(PressFeedbackModifier(isPressed: configuration.isPressed, pressedScale: enabled ? 0.986 : 1, pressedOpacity: enabled ? 0.95 : 1, pressedYOffset: enabled ? 1.0 : 0))
    }
}
