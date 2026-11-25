import SwiftUI

struct AuthorizationView: View {
    @ObservedObject var model: HoldModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("提前授权", systemImage: "lock.shield")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            if !model.authorizationFeedback.isEmpty {
                Text(model.authorizationFeedback)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.configuring {
                    ProgressView().controlSize(.small)
                    Text("等待 macOS 确认").font(.callout)
                } else {
                    if model.authorization != .ready {
                        Button(model.authorization == .stale ? "更新授权" : "提前授权") {
                            Task { await model.setPreauthorization(true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if model.authorization != .manual {
                        Button("撤销授权", role: .destructive) {
                            confirmingRemoval = true
                        }
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.configuring)
            }
        }
        .padding(24)
        .frame(width: 360)
        .confirmationDialog("撤销提前授权？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("撤销授权", role: .destructive) {
                Task { await model.setPreauthorization(false) }
            }
        } message: {
            Text("之后开启或结束保活时，macOS 会再次要求授权。")
        }
    }

    private var message: String {
        switch model.authorization {
        case .manual:
            return "由 macOS 确认一次，之后这个账号可以直接开启或结束保活。应用不会保存你的密码。"
        case .ready:
            return "这个账号已提前授权，可以直接开启或结束保活。"
        case .stale:
            return "提前授权已失效。可以更新授权，也可以撤销它。"
        }
    }
}
