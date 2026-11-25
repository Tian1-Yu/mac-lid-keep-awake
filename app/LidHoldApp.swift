import SwiftUI

@main
struct LidHoldApp: App {
    @StateObject private var model = HoldModel(backend: .local())
    @AppStorage("hold-duration-minutes") private var minutes = 30
    @State private var showingAuthorization = false

    var body: some Scene {
        Window("合盖保活", id: "main") {
            HoldView(status: model.status, minutes: $minutes, activate: { duration in
                Task { await model.activate(minutes: duration) }
            }, openAuthorization: {
                showingAuthorization = true
            })
            .sheet(isPresented: $showingAuthorization) {
                AuthorizationView(model: model)
            }
            .task { await model.observe() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appSettings) {
                Button("授权设置…") { showingAuthorization = true }
                    .keyboardShortcut(",", modifiers: .command)
                    .disabled(model.status.busy || model.status.canEnd)
            }
        }
    }
}
