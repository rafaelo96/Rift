import SwiftUI
import Contracts

// MARK: - RiftPreviewView
//
// Envoltorio de preview aislado: instancia `ContentView<PlayerStatePreviewStub>`.
// Este archivo solo existe para desarrollo de UI; la app real usa `RiftApp`.

@MainActor
struct RiftPreviewView: View {
    @StateObject private var state = PlayerStatePreviewStub()

    var body: some View {
        ContentView<PlayerStatePreviewStub>(state: state)
            .frame(minWidth: 780, minHeight: 480)
    }
}

#Preview {
    RiftPreviewView()
}