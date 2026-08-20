// FilterBar.swift
// The grid's filter, sort and view controls in one strip. Two things here are
// product decisions rather than layout:
//
//   · The boolean grammar is made legible (D39). Values inside a group OR — two flag
//     chips lit means "picked or rejected" — and the groups AND with each other. The
//     model already implements it; the bar's job is to make a photographer able to
//     read what they have asked for, which is why the second row spells the active
//     query back out as a sentence instead of leaving it implied by lit chips.
//   · Auto-advance is a visible toggle, never a hidden preference and never Caps-Lock
//     folklore (D35, docs/10 §10.4.1). It is the switch that decides what a cull
//     keystroke does next, so it is on screen with its state showing.
//
// Chrome here is zero-chroma (Law 7). The only hues are the colour-label swatches,
// which cannot be told apart without them, and they are the same values the cell
// badges use.

#if os(macOS)

import SwiftUI

struct FilterBar: View {
    @EnvironmentObject var state: AppState

    private static let labelOrder: [ColorLabel] = [.red, .yellow, .green, .blue, .purple]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                flagGroup
                separator
                ratingGroup
                separator
                labelGroup
                separator
                rawOnlyChip
                textFilter
                Spacer(minLength: 8)
                sortMenu
                autoAdvanceToggle
                sizeSlider
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)

            summaryRow
                .padding(.horizontal, 10)
                .padding(.bottom, 5)
        }
        .background(Lumen.panelBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Lumen.separator)
                .frame(height: 1)
        }
    }

    // MARK: Criteria

    private var flagGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Flag")
            chip(title: "Pick", systemImage: "flag.fill",
                 isOn: state.filter.flags.contains(.picked)) { toggleFlag(.picked) }
            chip(title: "Reject", systemImage: "xmark",
                 isOn: state.filter.flags.contains(.rejected)) { toggleFlag(.rejected) }
            chip(title: "Unflagged", systemImage: nil,
                 isOn: state.filter.flags.contains(.none)) { toggleFlag(.none) }
        }
    }

    private var ratingGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Rating")
            Text("≥")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
            ForEach(1...5, id: \.self) { value in
                Button {
                    state.filter.minRating = state.filter.minRating == value ? 0 : value
                } label: {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(value <= state.filter.minRating
                                         ? Lumen.primaryText : Lumen.trackColor)
                }
                .buttonStyle(.plain)
                .help("Rating \(value) or better")
            }
        }
    }

    private var labelGroup: some View {
        HStack(spacing: 3) {
            groupLabel("Label")
            ForEach(Self.labelOrder, id: \.rawValue) { label in
                Button {
                    toggleLabel(label)
                } label: {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(label.color)
                        .frame(width: 14, height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(state.filter.labels.contains(label)
                                              ? Lumen.primaryText : Color.black.opacity(0.35),
                                              lineWidth: state.filter.labels.contains(label) ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
                .help(label.displayName)
            }
            chip(title: "Unlabelled", systemImage: nil,
                 isOn: state.filter.labels.contains(.none)) { toggleLabel(.none) }
        }
    }

    private var rawOnlyChip: some View {
        chip(title: "RAW only", systemImage: nil, isOn: state.filter.rawOnly) {
            state.filter.rawOnly.toggle()
        }
    }

    private var textFilter: some View {
        HStack(spacing: 3) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)
            TextField("File name", text: $state.filter.text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Lumen.primaryText)
                .frame(width: 120)
            if !state.filter.text.isEmpty {
                Button {
                    state.filter.text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Lumen.secondaryText)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(Lumen.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: View controls

    private var sortMenu: some View {
        Menu {
            ForEach(SortOrder.allCases) { order in
                Button {
                    state.sortOrder = order
                } label: {
                    if order == state.sortOrder {
                        Label(order.rawValue, systemImage: "checkmark")
                    } else {
                        Text(order.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9))
                Text(state.sortOrder.rawValue)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help("Sort order")
    }

    private var autoAdvanceToggle: some View {
        Toggle(isOn: $state.autoAdvance) {
            HStack(spacing: 3) {
                Image(systemName: "forward.end.alt.fill")
                    .font(.system(size: 9))
                Text("Auto-advance")
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(state.autoAdvance ? Lumen.primaryText : Lumen.secondaryText)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .fixedSize()
        .help("After a flag, star or label, move to the next photo")
    }

    private var sizeSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 9))
                .foregroundStyle(Lumen.secondaryText)
            Slider(value: $state.gridThumbnailSize, in: 96...512)
                .controlSize(.mini)
                .tint(Lumen.fillColor)
                .frame(width: 100)
            Image(systemName: "square.fill")
                .font(.system(size: 10))
                .foregroundStyle(Lumen.secondaryText)
        }
        .help("Thumbnail size")
    }

    // MARK: Legibility row

    private var summaryRow: some View {
        HStack(spacing: 8) {
            Text(state.filter.isActive ? summary : "No filter — showing every photo")
                .font(.system(size: 10))
                .foregroundStyle(state.filter.isActive ? Lumen.primaryText : Lumen.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(countText)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Lumen.secondaryText)
            if state.filter.isActive {
                Button("Clear") { state.filter = LibraryFilter() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Lumen.primaryText)
            }
        }
    }

    /// The active query written out. "or" inside a criterion, "and" between them —
    /// the sentence is the documentation.
    private var summary: String {
        var parts: [String] = []
        if !state.filter.flags.isEmpty {
            let flags = state.filter.flags
                .sorted { $0.rawValue > $1.rawValue }
                .map(Self.flagName)
            parts.append(flags.joined(separator: " or "))
        }
        if state.filter.minRating > 0 {
            parts.append("★ \(state.filter.minRating) or better")
        }
        if !state.filter.labels.isEmpty {
            let labels = state.filter.labels
                .sorted { $0.rawValue < $1.rawValue }
                .map { $0 == ColorLabel.none ? "Unlabelled" : $0.displayName }
            parts.append(labels.joined(separator: " or "))
        }
        if state.filter.rawOnly {
            parts.append("RAW only")
        }
        if !state.filter.text.isEmpty {
            parts.append("name contains \"\(state.filter.text)\"")
        }
        return parts.joined(separator: "  and  ")
    }

    private var countText: String {
        let total = state.allPhotos.count
        guard state.filter.isActive else { return "\(total) photos" }
        return "\(matchCount) of \(total)"
    }

    /// Counted rather than read off `state.photos`, which would sort the library on
    /// every keystroke in the text field.
    private var matchCount: Int {
        var count = 0
        for photo in state.allPhotos where state.filter.matches(photo) { count += 1 }
        return count
    }

    private static func flagName(_ flag: PhotoFlag) -> String {
        switch flag {
        case .picked: return "Picked"
        case .rejected: return "Rejected"
        case .none: return "Unflagged"
        }
    }

    // MARK: Mutation

    private func toggleFlag(_ flag: PhotoFlag) {
        if state.filter.flags.contains(flag) {
            state.filter.flags.remove(flag)
        } else {
            state.filter.flags.insert(flag)
        }
    }

    private func toggleLabel(_ label: ColorLabel) {
        if state.filter.labels.contains(label) {
            state.filter.labels.remove(label)
        } else {
            state.filter.labels.insert(label)
        }
    }

    // MARK: Pieces

    private var separator: some View {
        Rectangle()
            .fill(Lumen.separator)
            .frame(width: 1, height: 16)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .foregroundStyle(Lumen.secondaryText)
    }

    private func chip(title: String,
                      systemImage: String?,
                      isOn: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 9))
                }
                Text(title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Lumen.primaryText : Lumen.secondaryText)
            .background(isOn ? Lumen.fillColor.opacity(0.35) : Lumen.controlBackground)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

#endif
