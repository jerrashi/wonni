/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI

struct CameraViewController: View {
    /// The Sell tab's whole navigation state. Lives here, not in MainView, so the
    /// stack and the only view that mutates it are declared together.
    @State private var path: [CameraRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            CameraView(path: $path)
                .onAppear {
                    applyCustomAppearance()
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
