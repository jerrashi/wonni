/*
See the License.txt file for this sample’s licensing information.
*/

import SwiftUI

struct CameraViewController: View {
    
    var body: some View {
        CameraView()
            .onAppear {
                applyCustomAppearance()
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
