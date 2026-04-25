import SwiftUI

struct QuickCaptureToast: View {
    let payload: QuickCaptureViewModel.ToastPayload
    let onUndo: () -> Void
    let onSplit: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: payload.kind == .merged ? "link.badge.plus" : "checkmark.circle.fill")
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(payload.kind == .merged ? "Added to \(payload.placeName)" : "Logged at \(payload.placeName)")
                    .font(.subheadline.bold())
            }

            Spacer()

            Button(payload.kind == .merged ? "Split" : "Undo") {
                payload.kind == .merged ? onSplit() : onUndo()
            }
            .buttonStyle(.borderless)
            .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 4, y: 2)
        .padding(.horizontal, 16)
        .onAppear {
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                onDismiss()
            }
        }
    }
}
