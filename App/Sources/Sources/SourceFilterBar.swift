import SwiftUI
import LanterneCore

/// Barre de filtres des sources : qualité, langue, addon (menus avec le nombre de
/// sources par option), HDR / Dolby Vision, effacement. Les compteurs tiennent
/// compte des autres filtres actifs.
struct SourceFilterBar: View {
    @Binding var filter: SourceFilter
    /// Sources triées, avant filtrage.
    let sources: [RankedSource]
    var compact = false

    var body: some View {
        HStack(spacing: 12) {
            menu(title: "Qualité", options: filter.resolutionOptions(sources), selection: $filter.resolutions)
            menu(title: "Langue", options: filter.languageOptions(sources), selection: $filter.languages)
            if filter.addonOptions(sources).count > 1 || !filter.addons.isEmpty {
                menu(title: "Addon", options: filter.addonOptions(sources), selection: $filter.addons)
            }
            let hdr = filter.hdrCount(sources)
            if hdr > 0 || filter.hdrOnly {
                Button {
                    filter.hdrOnly.toggle()
                } label: {
                    Text("HDR / DV \\(hdr)")
                }
                .buttonStyle(PillButtonStyle(selected: filter.hdrOnly, compact: compact))
            }
            if filter.isActive {
                Button {
                    filter = SourceFilter()
                } label: {
                    Label("Effacer", systemImage: "xmark")
                }
                .buttonStyle(PillButtonStyle(compact: compact))
            }
        }
        .focusSection()
    }

    private func menu(title: String, options: [SourceFilter.Option], selection: Binding<Set<String>>) -> some View {
        let active = selection.wrappedValue
        let label = active.isEmpty ? title : "\\(title) · \\(active.count)"
        return Menu {
            if !active.isEmpty {
                Button("Tout afficher") { selection.wrappedValue = [] }
            }
            ForEach(options) { option in
                Toggle(isOn: Binding(
                    get: { selection.wrappedValue.contains(option.key) },
                    set: { on in
                        if on { selection.wrappedValue.insert(option.key) } else { selection.wrappedValue.remove(option.key) }
                    }
                )) {
                    Text("\\(option.label)   \\(option.count)")
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(label)
                Image(systemName: "chevron.down").font(.system(size: compact ? 14 : 18, weight: .bold))
            }
        }
        .buttonStyle(PillButtonStyle(selected: !active.isEmpty, compact: compact))
        .disabled(options.isEmpty)
    }
}
