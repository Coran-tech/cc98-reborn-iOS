import SwiftUI

struct AddSoundLinkView: View {
    @EnvironmentObject private var store: SoundBoardStore
    @Environment(\.dismiss) private var dismiss

    @State private var link = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    private var canImport: Bool {
        !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isWorking
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                TextField("https://example.com/sound.mp3", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit(startImport)
                    .padding(.horizontal, 14)
                    .frame(height: 50)
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.white.opacity(0.07))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0xFCA5A5))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .background(Color(hex: 0x0B0D18).ignoresSafeArea())
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                    .disabled(isWorking)
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else {
                        Button("导入", action: startImport)
                            .disabled(!canImport)
                    }
                }
            }
        }
        .presentationDetents([.height(280)])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWorking)
        .preferredColorScheme(.dark)
        .onAppear {
            isFocused = true
        }
    }

    private func startImport() {
        guard canImport else { return }
        isFocused = false
        errorMessage = nil
        isWorking = true

        Task { @MainActor in
            do {
                try await store.importRemoteSound(from: link)
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
