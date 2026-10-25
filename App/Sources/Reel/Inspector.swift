import SwiftUI

/// The building blocks every inspector tab shares, so the tabs keep one rhythm: 16 points of inset,
/// 20 between sections, 8 inside a section, hints in caption under their control.
struct InspectorPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.gutter) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.section)
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    var hint: String?
    @ViewBuilder let content: Content

    init(_ title: String, hint: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
            if let hint { InspectorHint(hint) }
        }
    }
}

/// A short explanation under a control.
struct InspectorHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// What a list shows while it is empty.
struct InspectorPlaceholder: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }
}

/// The minus at the end of a list row.
struct RemoveButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(help)
            .accessibilityLabel(help)
    }
}

extension View {
    /// The sunken field behind multi-line text: summaries, notes, generated documents.
    func insetField() -> some View {
        scrollContentBackground(.hidden)
            .padding(Theme.Spacing.small)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).stroke(Theme.line))
    }
}
