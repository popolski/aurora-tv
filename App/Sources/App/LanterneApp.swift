import SwiftUI
import LanterneCore

@main
struct LanterneApp: App {
    @State private var model = AppModel.make()
    @State private var ambient = Ambient()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .tvCanvas()
                #if os(iOS)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                #endif
                .environment(model)
                .environment(ambient)
                .preferredColorScheme(.dark)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background, .inactive:
                // Écrit immédiatement la progression : l'app peut être tuée en arrière-plan.
                Task { await model.flushPersistentState() }
            case .active:
                Task { await model.refreshOnForeground() }
            @unknown default:
                break
            }
        }
    }
}
