import ImageIO
import SwiftUI

struct HoldView: View {
    let status: HoldStatus
    @Binding var minutes: Int
    let activate: (Int) -> Void
    let openAuthorization: () -> Void
    var icon: CGImage? = Self.icon
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false
    @State private var durationDraft: String?
    @FocusState private var actionFocused: Bool

    private static let icon: CGImage? = Bundle.main.url(forResource: "HeaderIcon", withExtension: "png")
        .flatMap { CGImageSourceCreateWithURL($0 as CFURL, nil) }
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }

    private var palette: Palette { Palette(dark: scheme == .dark, increasedContrast: contrast == .increased) }
    private var changeAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.23) }
    private var timeAnimation: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.19) }
    private var warning: Bool { status.phase == .blocked || status.phase == .recovery || status.phase == .failed }
    private var accent: Color { warning ? palette.caution : palette.accent }
    private var editedMinutes: Int? {
        let value = durationDraft ?? String(minutes)
        guard !value.isEmpty, value.count <= 3, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let amount = Int(value), (1...120).contains(amount) else { return nil }
        return amount
    }

    var body: some View {
        VStack(spacing: 15) {
            header
                .padding(.bottom, 4)
            dial
            statusDetail
            if status.canStart || status.canEnd || status.busy {
                action.transition(.opacity)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 424, height: 474, alignment: .top)
        .background {
            palette.canvas
            RadialGradient(colors: [palette.wash, palette.canvas.opacity(0)],
                           center: .topTrailing, startRadius: 0, endRadius: 420)
                .accessibilityHidden(true)
        }
        .foregroundStyle(palette.text)
        .animation(changeAnimation, value: status.phase)
        .animation(changeAnimation, value: status.detail)
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(decorative: icon, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 49, height: 49)
                    .padding(-3)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("合盖保活")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("合盖后开始计时")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
            Spacer(minLength: 0)
            if status.canStart || status.phase == .blocked {
                Button(action: openAuthorization) {
                    Label("授权设置", systemImage: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.secondary)
                .accessibilityLabel("授权设置")
                .help("授权设置")
                .transition(.opacity)
            }
        }
        .frame(height: 46)
    }

    private var dial: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .strokeBorder(palette.ring, lineWidth: 2)
                if status.phase == .waiting {
                    Circle()
                        .stroke(palette.accent.opacity(0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [2, 5]))
                        .transition(.opacity)
                } else {
                    Circle()
                        .trim(from: 0, to: status.ratio)
                        .stroke(AngularGradient(colors: [palette.accent, palette.arc], center: .center),
                                style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .opacity(status.ratio > 0 ? 1 : 0)
                        .transition(.opacity)
                        .animation(timeAnimation, value: status.ratio)
                }
                VStack(spacing: 3) {
                    ZStack {
                        Image(systemName: status.glyph)
                            .id(status.glyph)
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(accent)
                            .transition(.opacity)
                    }
                    .frame(width: 30, height: 27)
                    if status.phase == .holding {
                        Text(status.time)
                            .font(.system(size: 37, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                            .animation(timeAnimation, value: status.seconds)
                            .accessibilityLabel("剩余时间")
                            .accessibilityValue("\(status.seconds / 60) 分 \(status.seconds % 60) 秒")
                        Text("剩余时间")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondary)
                            .accessibilityHidden(true)
                    } else if status.canStart {
                        durationControl.transition(.opacity)
                    } else if status.phase == .waiting {
                        Text("\(status.duration / 60) 分钟")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("合盖后开始计时")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(palette.secondary)
                    }
                }
                .offset(y: -1)
            }
            .frame(width: 138, height: 138)
            .accessibilityElement(children: .contain)

            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 5, weight: .semibold))
                    .frame(width: 11, height: 12)
                    .foregroundStyle(status.phase == .idle || status.phase == .checking ? palette.secondary : accent)
                    .accessibilityHidden(true)
                Text(status.title)
                    .font(.system(size: 12, weight: .semibold))
                    .contentTransition(.opacity)
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .frame(height: 25)
            .background(accent.opacity(palette.dark ? 0.14 : 0.09), in: Capsule())
            .foregroundStyle(palette.text)
            .accessibilityLabel(status.title)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 206)
        .background(alignment: .center) {
            RoundedRectangle(cornerRadius: 25)
                .fill(LinearGradient(colors: [palette.cardTop, palette.cardBottom],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 25)
                .strokeBorder(palette.outline, lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var durationControl: some View {
        HStack(spacing: 4) {
            TextField("分钟数", text: Binding(
                get: { durationDraft ?? String(minutes) },
                set: { value in
                    durationDraft = value
                    if let valid = editedMinutes { minutes = valid }
                }
            ))
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .multilineTextAlignment(.center)
                .frame(width: 50, height: 31)
                .padding(.horizontal, 1)
                .background(palette.buttonNeutral, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(palette.outline, lineWidth: 1).allowsHitTesting(false))
                .accessibilityLabel("保活时长")
                .accessibilityHint("输入 1 到 120 分钟")
            Text("分钟")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
                .accessibilityHidden(true)
            Stepper(value: Binding(get: { minutes }, set: { value in minutes = value; durationDraft = nil }), in: 1...120) {
                Text("调整保活时长")
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .frame(height: 35)
    }

    private var statusDetail: some View {
        let invalid = status.canStart && editedMinutes == nil
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: warning || invalid ? "exclamationmark.circle" : "info.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            Text(invalid ? "请输入 1 到 120 分钟。" : status.detail)
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .foregroundStyle(palette.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
    }

    private var action: some View {
        let outlined = status.canEnd || warning || status.phase == .ending
        return Button {
            if status.canEnd { activate(minutes) }
            else if let editedMinutes { activate(editedMinutes) }
        } label: {
            HStack(spacing: 11) {
                ZStack {
                    if status.busy {
                        HoldSpinner(reduceMotion: reduceMotion)
                            .frame(width: 13, height: 13)
                            .transition(.opacity)
                    } else {
                        Image(systemName: status.actionSymbol)
                            .font(.system(size: 15, weight: .semibold))
                            .transition(.opacity)
                    }
                }
                .frame(width: 19, height: 19)
                .accessibilityHidden(true)
                Text(status.actionTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.opacity)
                Spacer(minLength: 0)
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .semibold))
                    .opacity(!warning && !status.canEnd && !status.busy ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .foregroundStyle(outlined ? palette.text : .white)
        }
        .buttonStyle(HoldButtonStyle(
            fill: outlined ? palette.buttonNeutral : palette.buttonPrimary,
            outline: outlined ? palette.outline : palette.buttonEdge,
            highlight: outlined ? palette.highlight : .white,
            hovering: hovering, focused: actionFocused, reduceMotion: reduceMotion
        ))
        .disabled(status.busy || (status.canStart && editedMinutes == nil))
        .onHover { hovering = $0 }
        .focused($actionFocused)
        .accessibilityLabel(status.actionTitle)
        .accessibilityHint(status.canEnd ? "恢复 Mac 的睡眠权限" : "使用上方设定的时长，合盖后开始计时")
    }
}

private struct HoldSpinner: View {
    let reduceMotion: Bool
    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().strokeBorder(lineWidth: 1.5).opacity(0.30)
            Circle().trim(from: 0, to: 0.64)
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
        }
        .animation(reduceMotion ? nil : .linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
        .onAppear { spinning = !reduceMotion }
        .onChange(of: reduceMotion) { _, reduced in spinning = !reduced }
    }
}

private struct HoldButtonStyle: ButtonStyle {
    let fill: Color
    let outline: Color
    let highlight: Color
    let hovering: Bool
    let focused: Bool
    let reduceMotion: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let activeHover = enabled && hovering
        let pressed = enabled && configuration.isPressed
        return configuration.label
            .background {
                RoundedRectangle(cornerRadius: 15)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 15)
                            .fill(highlight.opacity(pressed ? 0.15 : (activeHover ? 0.08 : 0)))
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15)
                    .strokeBorder(focused ? highlight.opacity(0.85) : outline,
                                  lineWidth: focused ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .scaleEffect(pressed && !reduceMotion ? 0.984 : 1)
            .opacity(enabled ? 1 : 0.79)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: activeHover)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: focused)
    }
}

private struct Palette {
    let dark: Bool
    let increasedContrast: Bool

    var canvas: Color { hex(dark ? 0x151D1B : 0xF6F8F5) }
    var wash: Color { hex(dark ? 0x2A483E : 0xE3F2E9).opacity(0.74) }
    var cardTop: Color { hex(dark ? 0x233A32 : 0xE7F1EB) }
    var cardBottom: Color { hex(dark ? 0x202C28 : 0xF7FAF7) }
    var outline: Color { hex(dark ? 0x739587 : 0x527969).opacity(increasedContrast ? 0.55 : 0.27) }
    var ring: Color { hex(dark ? 0x668A7D : 0x5C8B7C).opacity(increasedContrast ? 0.55 : 0.27) }
    var text: Color { hex(dark ? 0xEFF8F3 : 0x142822) }
    var secondary: Color { hex(dark ? 0xB6CFC4 : 0x415B52) }
    var accent: Color { hex(dark ? 0x9BE1C7 : 0x176553) }
    var arc: Color { hex(dark ? 0xD5F4DF : 0x4AA186) }
    var caution: Color { hex(dark ? 0xF4C384 : 0x8D4E13) }
    var buttonPrimary: Color { hex(dark ? 0x256653 : 0x175C49) }
    var buttonNeutral: Color { hex(dark ? 0x263A32 : 0xEFF5F0) }
    var buttonEdge: Color { hex(dark ? 0x76B5A3 : 0x113F34).opacity(0.50) }
    var highlight: Color { hex(dark ? 0xB0CFBE : 0x477C66) }

    private func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 255) / 255,
              green: Double((value >> 8) & 255) / 255,
              blue: Double(value & 255) / 255)
    }
}
