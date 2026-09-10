//
//  DesignGallery.swift
//  DesignSystem
//
//  Every token and primitive on one screen, in both appearances — the design
//  review tool. Open it from an Xcode preview.
//
//  It is a plain stack, not a scroll view: whoever shows it decides how, and a
//  renderer can then draw the whole of it at once. `ImageRenderer` only draws
//  a scroll view's visible slice, and a gallery nobody can render in full is
//  not a review tool.
//

import SwiftUI

#if DEBUG
    public struct DesignGallery: View {

        @State private var tab = "First"

        public init() {}

        public var body: some View {
            VStack(alignment: .leading, spacing: EchoSpacing.xl) {
                Text("Type").font(EchoFont.sectionTitle)
                VStack(alignment: .leading, spacing: EchoSpacing.s) {
                    Text("Document title")
                        .font(EchoFont.documentTitle)
                        .tracking(EchoFont.documentTitleTracking)
                    Text("Section title")
                        .font(EchoFont.sectionTitle)
                        .tracking(EchoFont.sectionTitleTracking)
                    Text("Body — a summary paragraph, with the leading the design gives it.")
                        .font(EchoFont.body).lineSpacing(EchoFont.bodyLineSpacing)
                    Text("Bold inside prose").font(EchoFont.bodyBold)
                    HStack(spacing: EchoSpacing.l) {
                        Text("Property label").font(EchoFont.propertyLabel)
                            .foregroundStyle(EchoColor.textTertiary)
                        Text("Property value").font(EchoFont.propertyValue)
                            .foregroundStyle(EchoColor.textValue)
                    }
                    HStack(spacing: EchoSpacing.l) {
                        Text("Row").font(EchoFont.row).foregroundStyle(EchoColor.textSecondary)
                        Text("Row, selected").font(EchoFont.rowSelected)
                        Text("Echo").font(EchoFont.appName).tracking(EchoFont.appNameTracking)
                        Text("Meetings").font(EchoFont.sectionLabel)
                            .tracking(EchoFont.sectionLabelTracking)
                            .foregroundStyle(EchoColor.textTertiary)
                        Text("Today").font(EchoFont.groupHeader)
                            .foregroundStyle(EchoColor.textQuaternary)
                    }
                    HStack(spacing: EchoSpacing.l) {
                        Text("Export").font(EchoFont.control)
                        Text("Summary").font(EchoFont.controlSelected)
                        Text("Summarized").font(EchoFont.statusPill)
                            .foregroundStyle(EchoColor.accent)
                        Text("micro label").font(EchoFont.micro)
                    }
                    Text("00:12:41 · 5,512 words · ⌘K · parakeet-tdt-0.6b-v3")
                        .font(EchoFont.mono(11.5))
                    Text("00:12:41").font(EchoFont.mono(19, weight: .medium))
                }

                Text("Color").font(EchoFont.sectionTitle)
                Text("Surfaces").font(EchoFont.micro).foregroundStyle(EchoColor.textTertiary)
                HStack {
                    swatch("window", EchoColor.windowBackground)
                    swatch("sidebar", EchoColor.sidebarBackground)
                    swatch("surface", EchoColor.surface)
                    swatch("raised", EchoColor.surfaceRaised)
                    swatch("selected", EchoColor.surfaceSelected)
                    swatch("divider", EchoColor.divider)
                    swatch("border", EchoColor.border)
                }

                Text("Text").font(EchoFont.micro).foregroundStyle(EchoColor.textTertiary)
                HStack {
                    swatch("primary", EchoColor.textPrimary)
                    swatch("prose", EchoColor.textProse)
                    swatch("value", EchoColor.textValue)
                    swatch("secondary", EchoColor.textSecondary)
                    swatch("tertiary", EchoColor.textTertiary)
                    swatch("quaternary", EchoColor.textQuaternary)
                    swatch("faint", EchoColor.textFaint)
                }

                Text("Roles").font(EchoFont.micro).foregroundStyle(EchoColor.textTertiary)
                HStack {
                    swatch("accent", EchoColor.accent)
                    swatch("wash", EchoColor.accentWash)
                    swatch("recording", EchoColor.recording)
                    swatch("selection", EchoColor.selection)
                    swatch("hover", EchoColor.hover)
                }

                Text("Buttons").font(EchoFont.sectionTitle)
                HStack {
                    Button("New recording") {}.buttonStyle(.echoPrimary)
                    Button("Export") {}.buttonStyle(.echoSecondary)
                    Button("Copy") {}.buttonStyle(.echoQuiet)
                    Button("Delete") {}.buttonStyle(.echoDestructive)
                }

                Text("Badges").font(EchoFont.sectionTitle)
                HStack {
                    StatusBadge("Summarized", tone: .success)
                    StatusBadge("Draft")
                    StatusBadge("Recording", tone: .recording)
                    StatusBadge("Failed", tone: .danger)
                    StatusBadge("Processing", tone: .accent)
                }

                Text("Meta strip").font(EchoFont.sectionTitle)
                MetaStrip([
                    MetaItem("calendar", "Aug 27, 2026 · 10:04 – 11:02"),
                    MetaItem("clock", "58 min"),
                    MetaItem("text.word.spacing", "5,512 words"),
                    MetaItem("checkmark.seal", "Summarized"),
                ])

                Text("Property rows").font(EchoFont.sectionTitle)
                VStack(alignment: .leading, spacing: 0) {
                    PropertyRow(symbol: "calendar", label: "Date") {
                        HStack(spacing: EchoSpacing.xs) {
                            Text("Aug 27, 2026 ·")
                            Text("10:04 – 11:02").font(EchoFont.mono(12.5))
                        }
                    }
                    PropertyRow(symbol: "clock", label: "Duration", "58 min")
                    PropertyRow(symbol: "text.alignleft", label: "Words") {
                        Text("5,512").font(EchoFont.mono(12.5))
                    }
                    PropertyRow(symbol: "display", label: "A value") {
                        HStack(spacing: EchoSpacing.xs) {
                            Text("With a value")
                            Text("· and a qualifier after it")
                                .font(EchoFont.statusPill.weight(.regular))
                                .foregroundStyle(EchoColor.textTertiary)
                        }
                    }
                    PropertyRow(symbol: "checkmark.circle", label: "Status") {
                        StatusBadge("Summarized", tone: .accent)
                    }
                }
                .frame(width: EchoLayout.readingWidth, alignment: .leading)

                Text("Tabs").font(EchoFont.sectionTitle)
                TabStrip(["First", "Second"], selection: $tab) { $0 }

                Text("The island").font(EchoFont.sectionTitle)
                VStack(alignment: .leading, spacing: EchoSpacing.l) {
                    HStack(spacing: EchoSpacing.s) {
                        // Role names, not a face's words: the faces belong to
                        // the island, and this sheet reviews the parts.
                        Button("Quiet") {}.buttonStyle(.islandQuiet)
                        Button("Secondary") {}.buttonStyle(.islandSecondary)
                        Button("Primary") {}.buttonStyle(.islandPrimary)
                        ValueChip("A value") {}
                        Button {
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.islandIcon)
                    }
                    HStack(spacing: EchoSpacing.m) {
                        LevelGauge("Accent", level: 0.64, tone: .accent)
                        LevelGauge("Neutral", level: 0.27, tone: .neutral)
                    }
                    .frame(width: 260)
                }
                .padding(EchoSpacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(EchoColor.Island.shell, in: .rect(cornerRadius: EchoRadius.window))

                Text("Empty state").font(EchoFont.sectionTitle)
                EmptyState(
                    symbol: "waveform",
                    title: "No meetings yet",
                    message: "Record a call and it will show up here with its transcript and notes."
                ) {
                    Button("New recording") {}.buttonStyle(.echoPrimary)
                }
                .frame(height: 260)
            }
            .padding(EchoSpacing.xl)
            // In the app the composition root registers the typefaces at
            // launch. A preview has no launch, so the gallery — the tool the
            // design is reviewed in — asks for them itself. Idempotent, and
            // the only reason this view has a task at all.
            .task { EchoFont.registerBundledTypefaces() }
        }

        private func swatch(_ name: String, _ color: Color) -> some View {
            VStack(spacing: EchoSpacing.xs) {
                RoundedRectangle(cornerRadius: EchoRadius.control)
                    .fill(color)
                    .frame(width: 56, height: 36)
                    .overlay(RoundedRectangle(cornerRadius: EchoRadius.control).strokeBorder(EchoColor.border))
                Text(name).font(EchoFont.micro).foregroundStyle(EchoColor.textSecondary)
            }
        }
    }

    #Preview("Gallery · light") {
        ScrollView { DesignGallery() }
            .frame(width: 900, height: 900)
            .background(EchoColor.windowBackground)
            .preferredColorScheme(.light)
    }

    #Preview("Gallery · dark") {
        ScrollView { DesignGallery() }
            .frame(width: 900, height: 900)
            .background(EchoColor.windowBackground)
            .preferredColorScheme(.dark)
    }
#endif
