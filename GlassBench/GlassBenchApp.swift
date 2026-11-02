import SwiftUI
import UIKit

@main
struct GlassBenchApp: App {
    @State private var bench = Bench()

    var body: some Scene {
        WindowGroup {
            BenchRoot(bench: bench)
                .statusBarHidden(true)
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    bench.start()
                }
        }
    }
}
