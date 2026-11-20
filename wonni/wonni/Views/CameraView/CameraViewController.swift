/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI
import SwiftData

struct CameraViewController: View {
    /// The Sell tab's whole navigation state lives on `SellRouter`, so the task row, the
    /// failed-publish alert and the launch-time restore can open a step of the flow.
    @ObservedObject private var router = SellRouter.shared
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationStack(path: $router.path) {
            CameraView(path: $router.path)
                .onAppear {
                    applyCustomAppearance()
                    router.restoreIfNeeded(modelContext: modelContext)
                }
        }
    }
    
    private func applyCustomAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.backgroundEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}
