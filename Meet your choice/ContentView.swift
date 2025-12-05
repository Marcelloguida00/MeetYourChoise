import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationView {
            VStack {
                Text("3D Dice")
                    .font(.largeTitle)
                    .padding()
                
                NavigationLink("Show Dice") {
                    DiceView()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
