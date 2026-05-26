import SwiftUI

// Triple-dot menu pinned to the top-right of feed cards. Wraps
// SwiftUI's native `Menu` — taps open an action-sheet style
// dropdown anchored to the trigger. Mirrors the web's
// SceneCardMenu surface (label + optional sub).
//
// `Menu` requires per-item Buttons; we expose a small Item DSL so
// call sites just declare a list. SwiftUI Menu doesn't render the
// sub-line natively, but multi-line `Text` inside a Button works
// in iOS 17+: title + smaller "sub" line render together.
struct SceneCardMenu: View {
    let items: [Item]

    struct Item {
        let label: String
        let systemImage: String
        let sub: String?
        let role: ButtonRole?
        let action: () -> Void

        init(
            label: String,
            systemImage: String,
            sub: String? = nil,
            role: ButtonRole? = nil,
            action: @escaping () -> Void
        ) {
            self.label = label
            self.systemImage = systemImage
            self.sub = sub
            self.role = role
            self.action = action
        }
    }

    var body: some View {
        Menu {
            ForEach(items.indices, id: \.self) { idx in
                let item = items[idx]
                Button(role: item.role, action: item.action) {
                    if let sub = item.sub {
                        // Two-line button: `Text` + Image works.
                        // Putting the sub as a second Text inside
                        // the Button label only works reliably in
                        // a Label's `title` slot via `Text +
                        // Text` concatenation.
                        Label {
                            VStack(alignment: .leading) {
                                Text(item.label)
                                Text(sub)
                                    .font(.caption2)
                            }
                        } icon: {
                            Image(systemName: item.systemImage)
                        }
                    } else {
                        Label(item.label, systemImage: item.systemImage)
                    }
                }
            }
        } label: {
            // 28pt hit target with a 16pt icon — same proportions
            // as the rest of the card chrome's icon buttons.
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}
