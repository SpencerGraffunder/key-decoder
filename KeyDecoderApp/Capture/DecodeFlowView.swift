import SwiftUI

/// Sheet shell for one decode session; drives DecodeFlow.step.
struct DecodeFlowView: View {
    @State private var flow = DecodeFlow()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.step {
        case .capture:
            CameraSheet(onPhoto: flow.handlePhoto)
                .navigationTitle("Photograph key")
                .navigationBarTitleDisplayMode(.inline)
        case .cardEditor:
            if let photo = flow.photo {
                CardQuadEditorView(image: photo, flow: flow)
            } else {
                CameraSheet(onPhoto: flow.handlePhoto)
            }
        case .processing:
            VStack(spacing: 12) {
                ProgressView()
                Text(flow.statusMessage.isEmpty ? "Analyzing card and key…" : flow.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding()
            .navigationTitle("Analyzing")
        case .review:
            ReviewView(flow: flow)
        case .result:
            ResultView(flow: flow)
        }
    }
}
