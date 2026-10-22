//
//  SearchPalette.swift
//  Workspace
//
//  The ⌘K palette, as the design draws it: a panel over the dimmed
//  window — the query and `esc`; the meetings found under a label that counts
//  them, each with its title, a line under it and its day, `↵` on the one the
//  keyboard is on; the actions with their shortcuts; and a strip of key hints
//  with what search reads. Spotlight's shape: the field keeps the focus, the
//  keyboard walks the list (`SearchPaletteKeys`), Return opens.
//
//  Search reads summaries and transcripts too (product owner, 2026-10-20,
//  reversing DEC-2), and that asks for what the artboard does not draw: the
//  line under a title can be a line of the summary or a turn of the
//  transcript, with where it came from before it; the filters a query's words
//  became sit in the field as pills, beside the scope Tab steps through; ⌘↵
//  opens a result on its other tab, ⌘1–⌘9 open the first nine, and ⌘C copies
//  the highlighted meeting's summary. While nothing is typed, the searches
//  the user last acted on come first; and ⌘K on a row opens its actions —
//  Raycast's panel — at the palette's foot.
//

import DesignSystem
import EchoCore
import Meetings
import Recording
import SwiftUI

struct SearchPalette: View {
    @Environment(MeetingLibrary.self) private var library
    @Environment(WorkspaceModel.self) private var workspace
    @Environment(RecordingSession.self) private var session
    @Environment(AppSettings.self) private var settings

    /// New recording: the window's own gated start.
    let startRecording: () -> Void

    /// What the last answered query found, all of it, best first.
    @State private var hits: [MeetingSearchHit] = []
    /// The query `hits` answers. Until a query is answered, the palette does
    /// not say it found nothing.
    @State private var answered: MeetingSearchQuery?
    /// The row the keyboard is on, over the meetings and then the actions.
    @State private var highlighted = 0
    @State private var commandHeld = false
    @State private var copied = false
    /// The row the keyboard is on in the highlighted row's actions panel;
    /// `nil` while the panel is shut.
    @State private var panel: Int?
    @State private var renameTarget: MeetingMeta?
    @State private var contentHeight: CGFloat = 0
    @State private var keys = PaletteKeyWatcher()
    @FocusState private var fieldFocused: Bool

    /// Answers again when the line changes, and when the index has read more.
    private struct SearchKey: Hashable {
        let query: MeetingSearchQuery
        let revision: Int
    }

    private var query: MeetingSearchQuery {
        MeetingSearchQuery.parse(workspace.searchText, scope: workspace.searchScope)
    }

    private var list: SearchPaletteList {
        let typed = !workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return SearchPaletteList(recents: typed ? [] : settings.recentSearches, hits: query.isEmpty ? [] : hits)
    }

    private var titleBar: TitleBarState {
        TitleBarState.resolve(phase: session.phase, readiness: session.readiness)
    }

    var body: some View {
        let query = query
        let list = list
        GeometryReader { window in
            ZStack(alignment: .top) {
                EchoColor.paletteScrim
                    .contentShape(.rect)
                    .onTapGesture { workspace.dismissSearch() }
                    .accessibilityHidden(true)
                panel(query, list, maxListHeight: maxListHeight(in: window.size.height))
                    .padding(.top, EchoLayout.paletteTopInset)
            }
        }
        .background(WindowReader { keys.window = $0 })
        .onAppear {
            keys.onKey = { key in handle(key) }
            keys.start()
            // The field exists once the palette has drawn.
            Task { fieldFocused = true }
        }
        .onDisappear { keys.stop() }
        .task { await library.prepareSearch() }
        .task(id: SearchKey(query: query, revision: library.searchRevision)) { await answer(query) }
        .onChange(of: workspace.searchText) { _, _ in
            highlighted = 0
            copied = false
            panel = nil
        }
        .onChange(of: workspace.searchScope) { _, _ in highlighted = 0 }
        .onChange(of: highlighted) { _, _ in
            copied = false
            panel = nil
        }
        .renameMeetingAlert($renameTarget)
        .onModifierKeysChanged(mask: .command) { _, now in commandHeld = now.contains(.command) }
    }

    /// The results scroll inside the palette rather than push it past the
    /// window's foot: what is left under the field and the hints, keeping
    /// the room above the palette below it too.
    private func maxListHeight(in height: CGFloat) -> CGFloat {
        let chrome = EchoLayout.paletteFieldHeight + EchoLayout.paletteFooterHeight + 2 * EchoLayout.hairline
        return max(EchoLayout.paletteActionHeight, height - 2 * EchoLayout.paletteTopInset - chrome)
    }

    private func answer(_ query: MeetingSearchQuery) async {
        let found = query.isEmpty ? [] : await library.search(query)
        guard !Task.isCancelled else { return }
        hits = found
        answered = query
        highlighted = list.clamped(highlighted)
    }

    // MARK: The panel

    private func panel(_ query: MeetingSearchQuery, _ list: SearchPaletteList, maxListHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            field(query)
            EchoColor.paletteDivider
                .frame(height: EchoLayout.hairline)
            results(query, list, maxHeight: maxListHeight)
            EchoColor.paletteDivider
                .frame(height: EchoLayout.hairline)
            footer(list)
        }
        .paletteSurface()
        // Over the lists, at their foot above the hints, and not clipped by
        // the palette's corners: a long panel may rise over the field.
        .overlay(alignment: .bottomTrailing) {
            if let panel, let item = list.item(at: highlighted) {
                actionsPanel(for: item, on: panel)
                    .padding(.trailing, EchoLayout.paletteListInset)
                    .padding(
                        .bottom, EchoLayout.paletteFooterHeight + EchoLayout.hairline + EchoLayout.paletteListInset)
            }
        }
    }

    // MARK: The query

    private func field(_ query: MeetingSearchQuery) -> some View {
        @Bindable var workspace = workspace
        return HStack(spacing: EchoLayout.paletteFieldGap) {
            PaletteGlyph(.magnifier)
                .stroke(
                    EchoColor.textTertiary, style: PaletteGlyph.stroke(at: EchoControl.paletteSearchGlyphSize)
                )
                .frame(width: EchoControl.paletteSearchGlyphSize, height: EchoControl.paletteSearchGlyphSize)
                .accessibilityHidden(true)
            ZStack(alignment: .leading) {
                if workspace.searchText.isEmpty {
                    // Decoration: the field carries the name for VoiceOver.
                    Text(SearchPaletteText.placeholder)
                        .foregroundStyle(EchoColor.textQuaternary)
                        .accessibilityHidden(true)
                }
                TextField("", text: $workspace.searchText)
                    .textFieldStyle(.plain)
                    .foregroundStyle(EchoColor.textPrimary)
                    .tint(EchoColor.accent)
                    .focused($fieldFocused)
                    .accessibilityLabel("Search")
            }
            .font(EchoFont.paletteQuery)
            .tracking(EchoFont.paletteQueryTracking)
            .lineLimit(1)
            // What the words became, so a filter word is never silently a
            // filter: quotes take it back.
            ForEach(query.filters, id: \.self) { filter in
                StatusBadge(filter.label, tone: .accent)
            }
            Button {
                workspace.searchScope = workspace.searchScope.stepped(by: 1)
            } label: {
                StatusBadge(workspace.searchScope.title, tone: workspace.searchScope == .all ? .neutral : .accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search \(workspace.searchScope.title)")
            .accessibilityHint("Tab changes what search reads")
            Keycap("esc")
        }
        // The palette's side inset, which its foot shares.
        .padding(.horizontal, EchoLayout.paletteFieldInset)
        .frame(height: EchoLayout.paletteFieldHeight)
    }

    // MARK: The lists

    private func results(_ query: MeetingSearchQuery, _ list: SearchPaletteList, maxHeight: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !list.recents.isEmpty {
                        PaletteGroupLabel(title: "Recent")
                        ForEach(Array(list.recents.enumerated()), id: \.element) { index, text in
                            recentRow(text, index: index)
                        }
                        PaletteRule()
                    }
                    if !query.isEmpty {
                        if list.total > 0 {
                            PaletteGroupLabel(title: "Meetings", count: list.total)
                            ForEach(Array(list.hits.enumerated()), id: \.element.id) { position, hit in
                                resultRow(hit, index: list.indexOfResult(at: position), list: list)
                            }
                            PaletteRule()
                        } else if answered == query && !library.isReadingForSearch {
                            noMatch
                            PaletteRule()
                        }
                    }
                    PaletteGroupLabel(title: "Actions")
                    ForEach(Array(PaletteAction.allCases.enumerated()), id: \.element) { position, action in
                        actionRow(action, index: list.indexOfAction(at: position))
                    }
                }
                .padding(EchoLayout.paletteListInset)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            .frame(height: min(contentHeight, maxHeight))
            .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
            .onChange(of: highlighted) { _, index in proxy.scrollTo(index) }
        }
    }

    /// In the results' place, with the one action out of it; the actions
    /// stay under it.
    private var noMatch: some View {
        EmptyState(
            glyph: .magnifier, title: SearchPaletteText.noMatchTitle(workspace.searchText),
            message: SearchPaletteText.noMatchMessage
        ) {
            Button("Clear search") {
                workspace.searchText = ""
                fieldFocused = true
            }
            .buttonStyle(.echoControl)
        }
    }

    // MARK: A result

    private func resultRow(_ hit: MeetingSearchHit, index: Int, list: SearchPaletteList) -> some View {
        let isOn = index == highlighted
        return HStack(spacing: EchoLayout.paletteRowGap) {
            PaletteGlyph(hit.meta.isTrashed ? .trash : .waveform)
                .stroke(
                    isOn ? EchoColor.accent : EchoColor.textQuaternary,
                    style: PaletteGlyph.stroke(at: EchoControl.paletteRowGlyphSize)
                )
                .frame(width: EchoControl.paletteRowGlyphSize, height: EchoControl.paletteRowGlyphSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                matched(hit.meta.title, hit.titleHighlights)
                    .font(EchoFont.rowTitle)
                    .foregroundStyle(isOn ? EchoColor.textPrimary : EchoColor.textProse)
                    .lineLimit(1)
                    .textRenderer(InlineHighlightRenderer())
                if let line = hit.line {
                    lineText(line)
                        .font(EchoFont.rowCaption)
                        .foregroundStyle(EchoColor.textTertiary)
                        .lineLimit(1)
                        .textRenderer(InlineHighlightRenderer())
                }
            }
            Spacer(minLength: EchoSpacing.s)
            Text(SearchPaletteText.day(hit.meta.startedAt))
                .font(EchoFont.mono(11))
                .foregroundStyle(EchoColor.textQuaternary)
                .fixedSize()
            if commandHeld, let number = list.shortcutNumber(forRowAt: index) {
                Keycap("⌘\(number)", isEmphasized: isOn)
            } else if isOn {
                Keycap("↵", isEmphasized: true)
            }
        }
        .padding(.horizontal, EchoLayout.paletteRowInset)
        .frame(height: EchoLayout.paletteResultHeight)
        .background { highlight(isOn) }
        .contentShape(.rect)
        .onTapGesture {
            highlighted = index
            activate(.meeting(hit), otherTab: false)
        }
        .id(index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: A recent search

    /// A search the user acted on before: Return puts it back in the field.
    private func recentRow(_ text: String, index: Int) -> some View {
        let isOn = index == highlighted
        return HStack(spacing: EchoLayout.paletteRowGap) {
            PaletteGlyph(.magnifier)
                .stroke(
                    isOn ? EchoColor.accent : EchoColor.textQuaternary,
                    style: PaletteGlyph.stroke(at: EchoControl.paletteRowGlyphSize)
                )
                .frame(width: EchoControl.paletteRowGlyphSize, height: EchoControl.paletteRowGlyphSize)
                .accessibilityHidden(true)
            Text(text)
                .font(EchoFont.rowTitle)
                .foregroundStyle(isOn ? EchoColor.textPrimary : EchoColor.textProse)
                .lineLimit(1)
            Spacer(minLength: EchoSpacing.s)
            if isOn { Keycap("↵", isEmphasized: true) }
        }
        .padding(.horizontal, EchoLayout.paletteRowInset)
        .frame(height: EchoLayout.paletteActionHeight)
        .background { highlight(isOn) }
        .contentShape(.rect)
        .onTapGesture {
            highlighted = index
            activate(.recent(text), otherTab: false)
        }
        .id(index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// The line under a title: the description as the sidebar would have
    /// it, or the summary's line or the transcript's turn the words were in,
    /// after where it came from.
    private func lineText(_ line: MeetingSearchHit.Line) -> Text {
        switch line {
        case .caption(let snippet):
            return matched(snippet.text, snippet.highlights)
        case .summary(let snippet):
            let source = Text("Summary · ").foregroundStyle(EchoColor.textQuaternary)
            return Text("\(source)\(matched(snippet.text, snippet.highlights))")
        case .transcript(let snippet, _, let speaker, let start):
            let time = Text(MeetingExport.timestamp(start)).font(EchoFont.mono(11))
            let source = Text("\(speaker.displayName) · \(time) · ").foregroundStyle(EchoColor.textQuaternary)
            return Text("\(source)\(matched(snippet.text, snippet.highlights))")
        }
    }

    /// Words with their matches in the accent, on its wash, as the artboard
    /// draws a match.
    private func matched(_ text: String, _ highlights: [Range<String.Index>]) -> Text {
        var result = Text(verbatim: "")
        var cursor = text.startIndex
        for range in highlights where range.lowerBound >= cursor && range.upperBound <= text.endIndex {
            if cursor < range.lowerBound {
                result = Text("\(result)\(Text(verbatim: String(text[cursor..<range.lowerBound])))")
            }
            let match = Text(verbatim: String(text[range]))
                .foregroundStyle(EchoColor.accent)
                .customAttribute(
                    InlineHighlight(
                        fill: EchoColor.accentWash, radius: EchoRadius.findMatch,
                        leading: EchoControl.paletteMatchInset.width, trailing: EchoControl.paletteMatchInset.width,
                        vertical: EchoControl.paletteMatchInset.height))
            result = Text("\(result)\(match)")
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result = Text("\(result)\(Text(verbatim: String(text[cursor...])))")
        }
        return result
    }

    // MARK: An action

    private func actionRow(_ action: PaletteAction, index: Int) -> some View {
        let isOn = index == highlighted
        let state = action.state(titleBar: titleBar)
        let available = state == .available
        return HStack(spacing: EchoLayout.paletteRowGap) {
            actionGlyph(action, available: available)
                .frame(width: EchoControl.paletteRowGlyphSize, height: EchoControl.paletteRowGlyphSize)
                .accessibilityHidden(true)
            Text(action.title)
                .font(EchoFont.rowTitle)
                .foregroundStyle(
                    available ? (isOn ? EchoColor.textPrimary : EchoColor.textProse) : EchoColor.textQuaternary
                )
                .lineLimit(1)
            Spacer(minLength: EchoSpacing.s)
            if case .heldBack(let reason?) = state {
                Text(reason)
                    .font(EchoFont.micro)
                    .foregroundStyle(EchoColor.textQuaternary)
                    .lineLimit(1)
            } else if available, let shortcut = action.shortcut {
                Keycap(shortcut, isEmphasized: isOn)
            }
        }
        .padding(.horizontal, EchoLayout.paletteRowInset)
        .frame(height: EchoLayout.paletteActionHeight)
        .background { highlight(isOn) }
        .contentShape(.rect)
        .onTapGesture {
            highlighted = index
            run(action)
        }
        .id(index)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func actionGlyph(_ action: PaletteAction, available: Bool) -> some View {
        switch action {
        case .startRecording:
            PaletteGlyph(.dot)
                .fill(available ? EchoColor.recording : EchoColor.textQuaternary)
        case .openSettings:
            PaletteGlyph(.gear)
                .stroke(EchoColor.textTertiary, style: PaletteGlyph.stroke(at: EchoControl.paletteRowGlyphSize))
        case .openTrash:
            PaletteGlyph(.trash)
                .stroke(EchoColor.textTertiary, style: PaletteGlyph.stroke(at: EchoControl.paletteRowGlyphSize))
        case .showShortcuts:
            PaletteGlyph(.keyboard)
                .stroke(EchoColor.textTertiary, style: PaletteGlyph.stroke(at: EchoControl.paletteRowGlyphSize))
        }
    }

    @ViewBuilder
    private func highlight(_ isOn: Bool) -> some View {
        if isOn {
            RoundedRectangle(cornerRadius: EchoRadius.paletteRow)
                .fill(EchoColor.paletteHighlight)
        }
    }

    // MARK: A row's actions

    /// What can be done to the highlighted row, Raycast's way: its name, then
    /// its actions, each with the key that does the same from the list.
    private func actionsPanel(for item: SearchPaletteList.Item, on row: Int) -> some View {
        let actions = PaletteItemAction.actions(for: item)
        return VStack(alignment: .leading, spacing: 0) {
            PaletteGroupLabel(title: panelTitle(of: item))
            ForEach(Array(actions.enumerated()), id: \.element) { position, action in
                let isOn = position == row
                HStack(spacing: EchoSpacing.s) {
                    Text(action.title)
                        .font(EchoFont.rowTitle)
                        .foregroundStyle(isOn ? EchoColor.textPrimary : EchoColor.textProse)
                        .lineLimit(1)
                    Spacer(minLength: EchoSpacing.s)
                    if let shortcut = action.shortcut(for: item) {
                        Keycap(shortcut, isEmphasized: isOn)
                    }
                }
                .padding(.horizontal, EchoLayout.paletteRowInset)
                .frame(height: EchoLayout.palettePanelRowHeight)
                .background { highlight(isOn) }
                .contentShape(.rect)
                .onTapGesture { perform(action, on: item) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(EchoLayout.paletteListInset)
        .frame(width: EchoLayout.palettePanelWidth)
        .background(EchoColor.paletteBackground, in: .rect(cornerRadius: EchoRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: EchoRadius.card)
                .strokeBorder(EchoColor.paletteBorder, lineWidth: EchoLayout.hairline)
        }
        .shadow(
            color: EchoColor.paletteShadow, radius: EchoLayout.palettePanelShadowRadius,
            y: EchoLayout.palettePanelShadowOffset)
    }

    private func panelTitle(of item: SearchPaletteList.Item) -> String {
        switch item {
        case .meeting(let hit): return hit.meta.title
        case .recent(let text): return text
        case .action(let action): return action.title
        }
    }

    // MARK: The foot

    private func footer(_ list: SearchPaletteList) -> some View {
        HStack(spacing: EchoLayout.paletteFooterGap) {
            KeyHint(key: "↑↓", label: "Move")
            KeyHint(key: "↵", label: "Open")
            if case .meeting(let hit)? = list.item(at: highlighted) {
                KeyHint(key: "⌘↵", label: hit.foundInTranscript ? "Open Summary" : "Open Transcript")
            }
            if let item = list.item(at: highlighted), !PaletteItemAction.actions(for: item).isEmpty {
                KeyHint(key: "⌘K", label: "Actions")
            }
            Spacer(minLength: 0)
            Text(SearchPaletteText.scopeLine(isReading: library.isReadingForSearch, copied: copied))
                .font(EchoFont.micro)
                .foregroundStyle(EchoColor.textFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, EchoLayout.paletteFieldInset)
        .frame(height: EchoLayout.paletteFooterHeight)
        .background(EchoColor.paletteFooter)
    }

    // MARK: Keys and actions

    /// What a key does; `false` hands it back to the field. While a row's
    /// actions panel is open, the keys walk the panel, and Esc or ⌘K shut it.
    private func handle(_ key: PaletteKey) -> Bool {
        let list = list
        if let row = panel, let item = list.item(at: highlighted) {
            let actions = PaletteItemAction.actions(for: item)
            switch key {
            case .move(let offset):
                panel = min(max(row + offset, 0), max(actions.count - 1, 0))
            case .open:
                if actions.indices.contains(row) { perform(actions[row], on: item) }
            case .escape, .actions:
                panel = nil
            case .stepScope, .openResult, .copySummary:
                break
            }
            return true
        }
        switch key {
        case .actions:
            // A row with no panel: the window's ⌘K, which puts the palette away.
            guard let item = list.item(at: highlighted), !PaletteItemAction.actions(for: item).isEmpty else {
                return false
            }
            panel = 0
        case .move(let offset):
            highlighted = list.moved(from: highlighted, by: offset)
        case .open(let otherTab):
            activate(list.item(at: highlighted), otherTab: otherTab)
        case .stepScope(let offset):
            workspace.searchScope = workspace.searchScope.stepped(by: offset)
        case .openResult(let number):
            guard let index = list.indexOfResult(number: number) else { return false }
            activate(list.item(at: index), otherTab: false)
        case .copySummary:
            guard case .meeting(let hit)? = list.item(at: highlighted), hit.meta.hasSummary else { return false }
            settings.noteSearch(workspace.searchText)
            copySummary(of: hit)
        case .escape:
            // Spotlight's two steps: the first clears what is typed, the
            // second puts the palette away.
            if workspace.searchText.isEmpty {
                workspace.dismissSearch()
            } else {
                workspace.searchText = ""
            }
        }
        return true
    }

    /// Opening a result is acting on the search, and keeps it among the
    /// recent ones; a recent one goes back in the field to be searched again.
    private func activate(_ item: SearchPaletteList.Item?, otherTab: Bool) {
        switch item {
        case .recent(let text):
            workspace.searchText = text
        case .meeting(let hit):
            settings.noteSearch(workspace.searchText)
            workspace.open(hit, otherTab: otherTab, findText: query.findText)
        case .action(let action):
            run(action)
        case nil:
            break
        }
    }

    /// Runs one of a row's actions and shuts its panel. Rename asks over the
    /// palette and leaves it up; Export and Reveal in Finder put it away,
    /// because a save panel or Finder is where the user goes next.
    private func perform(_ action: PaletteItemAction, on item: SearchPaletteList.Item) {
        panel = nil
        switch (action, item) {
        case (.open(let tab), .meeting(let hit)):
            activate(item, otherTab: tab != PaletteItemAction.primaryTab(of: hit))
        case (.copySummary, .meeting(let hit)):
            settings.noteSearch(workspace.searchText)
            copySummary(of: hit)
        case (.rename, .meeting(let hit)):
            settings.noteSearch(workspace.searchText)
            renameTarget = hit.meta
        case (.export(let format), .meeting(let hit)):
            settings.noteSearch(workspace.searchText)
            workspace.dismissSearch()
            Task {
                if let record = await library.loadRecord(hit.id) {
                    MeetingActions.export(record, as: format)
                }
            }
        case (.revealInFinder, .meeting(let hit)):
            settings.noteSearch(workspace.searchText)
            workspace.dismissSearch()
            MeetingActions.revealInFinder(library.directory(for: hit.id))
        case (.restore, .meeting(let hit)):
            settings.noteSearch(workspace.searchText)
            Task { await library.restore(hit.id) }
        case (.searchAgain, .recent):
            activate(item, otherTab: false)
        case (.forgetSearch, .recent(let text)):
            settings.forgetSearch(text)
        case (.clearRecentSearches, _):
            settings.clearRecentSearches()
        default:
            break
        }
    }

    private func run(_ action: PaletteAction) {
        switch action {
        case .startRecording:
            guard action.state(titleBar: titleBar) == .available else { return }
            workspace.dismissSearch()
            startRecording()
        case .openSettings:
            workspace.dismissSearch()
            workspace.section = .settings
        case .openTrash:
            workspace.dismissSearch()
            workspace.showTrash()
        case .showShortcuts:
            workspace.presentShortcuts()
        }
    }

    private func copySummary(of hit: MeetingSearchHit) {
        Task {
            guard let record = await library.loadRecord(hit.id) else { return }
            copied = MeetingActions.copySummary(record.summaryMarkdown, meta: record.meta)
        }
    }
}

/// The palette's glyphs, on the artboard's 16-point grid: the magnifier in
/// the query's row, the waveform before a meeting (the trash before a
/// trashed one), and the actions' dot, gear, trash and keyboard — the last
/// not drawn by the artboard, which has no keyboard shortcuts action, and
/// drawn here in its stroke. Drawn, not SF Symbols: the artboard draws its
/// own, and only the palette draws these.
private nonisolated struct PaletteGlyph: Shape {
    enum Kind {
        case magnifier
        case waveform
        case gear
        case trash
        case dot
        case keyboard
    }

    let kind: Kind

    init(_ kind: Kind) {
        self.kind = kind
    }

    /// The artboard's stroke, scaled with the glyph.
    static func stroke(at size: CGFloat) -> StrokeStyle {
        StrokeStyle(lineWidth: EchoControl.paletteGlyphStroke * size / 16, lineCap: .round, lineJoin: .round)
    }

    func path(in rect: CGRect) -> Path {
        let grid = GlyphGrid(rect: rect)
        var path = Path()
        func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) {
            path.move(to: grid.point(x1, y1))
            path.addLine(to: grid.point(x2, y2))
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) {
            let centre = grid.point(x, y)
            let r = grid.length(radius)
            path.addEllipse(in: CGRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        }
        switch kind {
        case .magnifier:
            circle(7.2, 7.2, 4.4)
            line(10.5, 10.5, 13.8, 13.8)
        case .waveform:
            line(2.4, 7.2, 2.4, 8.8)
            line(5.2, 5, 5.2, 11)
            line(8, 2.6, 8, 13.4)
            line(10.8, 5, 10.8, 11)
            line(13.6, 7.2, 13.6, 8.8)
        case .gear:
            circle(8, 8, 2.3)
            line(8, 1.9, 8, 3.7)
            line(8, 12.3, 8, 14.1)
            line(14.1, 8, 12.3, 8)
            line(3.7, 8, 1.9, 8)
            line(12.3, 3.7, 11, 5)
            line(5, 11, 3.7, 12.3)
            line(12.3, 12.3, 11, 11)
            line(5, 5, 3.7, 3.7)
        case .trash:
            line(3.4, 4.4, 12.6, 4.4)
            path.move(to: grid.point(6.4, 4.4))
            path.addArc(tangent1End: grid.point(6.4, 2.3), tangent2End: grid.point(9.6, 2.3), radius: grid.length(0.9))
            path.addArc(tangent1End: grid.point(9.6, 2.3), tangent2End: grid.point(9.6, 4.4), radius: grid.length(0.9))
            path.addLine(to: grid.point(9.6, 4.4))
            path.move(to: grid.point(4.7, 4.4))
            path.addLine(to: grid.point(5.3, 12.5))
            path.addQuadCurve(to: grid.point(6.3, 13.4), control: grid.point(5.35, 13.4))
            path.addLine(to: grid.point(9.7, 13.4))
            path.addQuadCurve(to: grid.point(10.7, 12.5), control: grid.point(10.65, 13.4))
            path.addLine(to: grid.point(11.3, 4.4))
        case .dot:
            circle(8, 8, 5.2)
        case .keyboard:
            path.addRoundedRect(
                in: CGRect(
                    origin: grid.point(1.8, 3.6), size: CGSize(width: grid.length(12.4), height: grid.length(8.8))),
                cornerSize: CGSize(width: grid.length(1.6), height: grid.length(1.6)))
            for x in [4.6, 7, 9.4, 11.8] { line(x, 6.4, x + 0.01, 6.4) }
            line(5.2, 9.6, 10.8, 9.6)
        }
        return path
    }
}
