import SwiftUI

// Action-stack overflow menu. Mirrors src/components/MoreSheet.tsx
// minus "Open in Stash" — on iOS we don't have a web frontend
// destination so that action is dropped. Auto-scroll is the only
// option for v0.2; future items slot in as additional rows.
struct MoreSheet: View {
    @AppStorage("binge.autoScroll") private var autoScroll: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    row(
                        title: "Auto-scroll",
                        subtitle: "advance to next scene when the "
                            + "current one ends",
                        isOn: Binding(
                            get: { autoScroll },
                            set: { autoScroll = $0 }
                        )
                    )
                }
                .padding(.top, 8)
            }
            .background(Color(white: 0.07).ignoresSafeArea())
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(.white)
                }
            }
            .toolbarBackground(Color(white: 0.07), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func row(
        title: String,
        subtitle: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(Color.bingeLike)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            isOn.wrappedValue.toggle()
        }
    }
}
