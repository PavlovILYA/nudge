import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("Nudge")
                .font(.title)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.1")")
            Text("Nudge is running")
        }
        .padding()
    }
}
