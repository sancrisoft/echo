//
//  SummaryPrompts.swift
//  Summarization
//
//  Every prompt the summarizer sends, and the transcript rendering they read.
//
//  The wording here is measured, not drafted. It was distilled from five real
//  Notion AI meeting summaries — the product owner's calibration target — and
//  then corrected against runs on the actual 4B model. Several phrases are
//  load-bearing and pinned by tests; reword freely AROUND them, never through
//  them. Where a rule appears twice, the repetition is the fix, and the comment
//  above it says what was measured without it.
//
//  Two structural decisions worth knowing before editing:
//
//  The shared ruleset is ONE constant interpolated verbatim into both the
//  single-pass and the reduce system prompts, so the two routes' documents
//  cannot drift apart in adaptivity, specificity, hedging, formatting, language
//  or speaker naming.
//
//  The closing reminder is appended AFTER the transcript (single pass) and
//  AFTER the material (reduce) — the very end of the context, where a small
//  model weighs instructions most. That slot is zero-sum, which is why the
//  reminder carries all three of its rules in one sentence rather than being
//  split into three.
//

import EchoCore
import Foundation

enum SummaryPrompts {

    // MARK: - The shared ruleset

    /// The route-independent half of the adaptive ruleset. Shared VERBATIM by
    /// the single-pass prompt and the reduce prompt. Wording is short and
    /// imperative on purpose: a small model follows rules it can quote, not
    /// meta-discussion.
    static let adaptiveSharedRules = """
        Adapt the amount to the meeting:
        - The number of sections and bullets follows the meeting's information
          density. A short or thin meeting gets short notes; a dense meeting gets
          many sections. Never pad. Never compress distinct topics into one line.

        Content:
        - Preserve specifics exactly as discussed: numbers, quantities, thresholds,
          versions, model and product names, amounts of money, and root-cause chains
          (symptom, cause, fix). These details are the value of the notes.
        - Omit social small talk entirely — personal stories, trips, jokes:
          no section, no mention, however long it took. An outside event earns a
          brief contextual section only when it changed the work — a plan, a
          decision, or a deadline.
        - The transcript is machine-transcribed and may be garbled. When a passage
          is unclear, hedge ("likely", "apparently", "unclear whether...") instead
          of inventing details or silently dropping the topic.

        Formatting:
        - Bullets are full, informative sentences.
        - Bold key terms sparingly, with **bold**.
        - Nest sub-bullets only for real hierarchy.
        - Use a table only when the content is truly tabular (a comparison, an
          option matrix).
        - "---" is allowed as a divider after a long Action Items list.

        Language: write the notes in the dominant language of the transcript.

        Speakers: "You" is the current user (microphone); "Team" are the other
        participants (system audio). Use real names when the transcript makes them
        clear; otherwise keep "You" and "the team".
        """

    // MARK: - The closing reminder

    /// One closing reminder, appended last on both routes.
    ///
    /// The small-talk omission rule sitting only in the far-away system prompt
    /// measured 6/6 leaks, which is why it is repeated here. The recency slot is
    /// zero-sum: the small-talk line ALONE displaced the ownership rule and the
    /// owner trap went from 4/4 to 0/2, so the reminder carries both traps. The
    /// language sentence is APPENDED after them and never replaces anything.
    ///
    /// One shared function so the two routes' reminders cannot drift apart.
    static func workNotesReminder(language: String?) -> String {
        var reminder =
            "Reminder: these are WORK notes. Leave out all social and personal "
            + "conversation (stories, trips, history, jokes) — no section, no mention. "
            + "Name an owner only on a task someone explicitly took; "
            + "a task nobody took gets its checkbox with NO name."
        if let language {
            reminder += " Write the notes in \(language)."
        }
        return reminder
    }

    // MARK: - Single-pass route

    /// Role and output contract first, document shape next (both anchored to the
    /// transcript), then the shared ruleset.
    static let markdownSystem = """
        You are an expert meeting note-taker. Write the notes a colleague who missed
        the meeting would need. Output ONE Markdown document and nothing else — no
        preamble, no closing remarks, no code fences.

        Document shape:
        - Sweep the WHOLE transcript for commitments first — a commitment made in
          passing, mid-topic, still counts. If any were made, START the document
          with a "### Action Items" section: a checkbox list with one
          "- [ ] Name to <verb> ..." item per commitment actually made in the
          transcript; a commitment discussed inside a topic gets BOTH its checkbox
          here and its topic coverage. Name an owner ONLY when that person took
          the task — said they would do it, or accepted it when asked. Whoever
          merely mentioned or requested a task is NOT its owner: write that item
          with no name, like "- [ ] Fix the login bug" —
          naming someone who did not take the task is an error.
          NEVER invent an owner or a due date; include a due date only when
          someone said it. If no commitments were made, do not write an Action
          Items section.
        - After that, write one "###" section per distinct work topic actually
          discussed. Make every title SPECIFIC to the content, like "Audio Bug:
          Wireless Headphone Frequency Issue" — never a generic bucket like
          "Discussion", "Updates", or "Miscellaneous". Use a generic category
          section only when the meeting earns it: "Key Decisions" only if explicit
          decisions were made; a context section only if outside events shaped the
          meeting. NEVER write an empty section, a "(none)" placeholder, or a
          section for a category with nothing in it.

        \(adaptiveSharedRules)
        """

    /// Deliberately thin: the ruleset lives in the system prompt and the
    /// transcript line format explains itself, so one legend line is enough.
    ///
    /// A detected language is stated twice — as framing here, and as the
    /// reminder's closing sentence.
    static func markdownUser(for segments: [TranscriptSegment], language: String?) -> String {
        let framing = language.map { "Write the notes in \($0).\n\n" } ?? ""
        return """
            Write the meeting notes for this transcript.

            \(framing)Each transcript line is "[start-end] Speaker: text".

            Transcript:
            \(plainTranscriptText(from: segments))

            \(workNotesReminder(language: language))
            """
    }

    // MARK: - Map phase

    static let mapSystem = """
        You extract structured facts from ONE part of a longer meeting transcript for
        a local-first macOS app. You are given only this part; other parts are handled
        separately, so summarize only what this part supports.
        Use only the transcript text provided by the user.
        Do not invent decisions, action item owners, due dates, risks, or blockers.
        If an owner or due date is unclear, use null.
        Do not infer calendar dates from relative wording.

        Output format: NDJSON. Emit ONE JSON object per line and nothing else —
        no prose, no Markdown, no code fences. Each line is one complete JSON object.

        Allowed line shapes:
        {"type":"chunknote","text":"a detailed 4-8 sentence note on this part"}
        {"type":"decision","title":"...","details":"...","evidence":["segment-id"]}
        {"type":"action","task":"...","owner":"... or null","due":"... or null","evidence":["segment-id"]}
        {"type":"question","question":"...","context":"... or null","evidence":["segment-id"]}
        {"type":"risk","risk":"...","details":"... or null","evidence":["segment-id"]}

        Rules:
        - Emit exactly one "chunknote" line first. Write a detailed note of 4-8 sentences
          in the dominant language of the transcript: name the topics discussed in
          this part AND the concrete specifics mentioned — numbers, amounts, names,
          versions, thresholds, root causes. The final summary is written from
          these notes, so it can only be as specific as they are.
        - Then emit zero or more decision, action, question, and risk lines. A part
          may contain none — that is fine; still emit the chunknote.
        - Every decision, action, question, and risk line must include at least one
          evidence segment-id copied verbatim from the transcript below.
        - If a claim cannot be supported by a transcript segment, omit it.
        - Some lines at the start are marked (overlap): they were already covered by
          the previous part. Do NOT report a fact whose evidence is entirely from
          (overlap) lines. If a fact spans an (overlap) line and a new one, report it
          and cite both.
        - List each distinct decision, action item, question, and risk only once.
        - "You" means the current user; "Team" means teammates from system audio.
        """

    /// On the long route the reduce writes from the chunk notes, so their
    /// language decides the final document's language — instruct it explicitly
    /// when detected.
    static func mapUser(for chunk: TranscriptChunk, language: String?) -> String {
        let languageInstruction = language.map { " Write the chunknote in \($0)." } ?? ""
        return """
            Extract structured facts from this PART of a meeting transcript as NDJSON.\(languageInstruction)

            Each transcript line is formatted as:
            [start-end][speaker][channel][id=SEGMENT_ID]: text
            Lines marked (overlap) were already covered by the previous part.
            Copy the SEGMENT_ID values into "evidence".

            Transcript part:
            \(chunkTranscriptText(for: chunk))
            """
    }

    // MARK: - Reduce phase

    /// The SAME adaptive document as the single-pass route — the shared ruleset
    /// is interpolated verbatim — but grounded in the map phase's material
    /// instead of a transcript.
    static let reduceSystem = """
        You are an expert meeting note-taker. The meeting was too long for one
        pass, so it was processed in parts: the user gives you each part's note in
        chronological order with its time range, plus the merged, de-duplicated
        facts extracted from the whole meeting. Write the notes a colleague who
        missed the meeting would need, grounded ONLY in that material.
        Do NOT introduce any decision, action, owner, due date, question, or risk
        that is not present in the material provided. Do not invent details.
        Output ONE Markdown document and nothing else — no preamble, no closing
        remarks, no code fences.

        Document shape:
        - If the material lists action items, START the document with a
          "### Action Items" section: a checkbox list with one
          "- [ ] Name to <verb> ..." item per action item in the material — those
          are the only candidates. If an action item has no owner, write the item
          without a name. NEVER invent an owner or a due date; include a due date
          only when the material carries one. If the material lists no action
          items, do not write an Action Items section.
        - After that, write one "###" section per distinct work topic in the part
          notes. Make every title SPECIFIC to the content, like "Audio Bug:
          Wireless Headphone Frequency Issue" — never a generic bucket like
          "Discussion", "Updates", or "Miscellaneous". Use a generic category
          section only when the meeting earns it: "Key Decisions" only if the
          material lists decisions; a context section only if outside events
          shaped the meeting. NEVER write an empty section, a "(none)" placeholder,
          or a section for a category with nothing in it.
        - Cover the whole meeting, using the ordered part notes for the arc.

        \(adaptiveSharedRules)
        """

    /// The reduce's material: part notes first (chronological, time-ranged — the
    /// meeting's arc), then ONLY the fact sections that have content.
    ///
    /// Empty sections are omitted entirely. A "(none)" line here would tempt the
    /// model into writing an empty section in the document, which is exactly what
    /// the ruleset forbids. Owner and due decorate an action item only when the
    /// merge actually carries them — never "unspecified" filler, which reads like
    /// material to preserve.
    static func reduceUser(facts: MergedFacts, notes: [ChunkMapResult], language: String?) -> String {
        var lines: [String] = [
            "Write the meeting notes from this material. Use ONLY the material",
            "below and add nothing new.",
        ]
        if let language {
            lines.append("Write the notes in \(language).")
        }

        let partNotes = notes.compactMap { note -> String? in
            let gist = note.chunkNote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !gist.isEmpty else { return nil }
            return "[\(timestamp(note.start))-\(timestamp(note.end))] \(gist)"
        }
        if !partNotes.isEmpty {
            lines.append("")
            lines.append("Part notes (in chronological order):")
            lines.append(contentsOf: partNotes)
        }

        if !facts.decisions.isEmpty {
            lines.append("")
            lines.append("Decisions:")
            lines.append(
                contentsOf: facts.decisions.map { decision in
                    let details = decision.details.trimmingCharacters(in: .whitespacesAndNewlines)
                    return details.isEmpty ? "- \(decision.title)" : "- \(decision.title): \(details)"
                })
        }

        if !facts.actionItems.isEmpty {
            lines.append("")
            lines.append("Action items:")
            lines.append(
                contentsOf: facts.actionItems.map { action in
                    var decorations: [String] = []
                    if let owner = action.owner { decorations.append("owner: \(owner)") }
                    if let due = action.dueDate { decorations.append("due: \(due)") }
                    return decorations.isEmpty
                        ? "- \(action.task)"
                        : "- \(action.task) (\(decorations.joined(separator: ", ")))"
                })
        }

        if !facts.openQuestions.isEmpty {
            lines.append("")
            lines.append("Open questions:")
            lines.append(contentsOf: facts.openQuestions.map { "- \($0.question)" })
        }

        if !facts.risks.isEmpty {
            lines.append("")
            lines.append("Risks:")
            lines.append(contentsOf: facts.risks.map { "- \($0.risk)" })
        }

        // The reduce's leak channel is chunk notes carrying social content, so
        // the material closes on the same reminder the single-pass prompt ends on.
        lines.append("")
        lines.append(workNotesReminder(language: language))

        return lines.joined(separator: "\n")
    }

    // MARK: - Row caption

    static let captionSystem = """
        You write a single, concise sentence that captures what a meeting was about, \
        in plain English. Output ONLY that one sentence: no preamble, no quotation \
        marks, no bullet points, no more than 16 words. Ground it strictly in the \
        notes provided; never invent specifics.
        """

    static func captionUser(_ notes: String) -> String {
        """
        Meeting notes:

        \(notes)

        One sentence describing this meeting:
        """
    }

    // MARK: - Transcript rendering

    /// The Markdown route's rendering: derived utterances, minus the channel tag
    /// and the segment ids.
    ///
    /// The Markdown prompt has no evidence protocol, and ids only invite the
    /// model to quote them into the notes. Both routes render from
    /// `TranscriptUtterance.derive` so they can never disagree about what was
    /// merged or filtered.
    static func plainTranscriptText(from segments: [TranscriptSegment]) -> String {
        TranscriptUtterance.derive(from: segments)
            .map { utterance in
                let span = "[\(timestamp(utterance.start))-\(timestamp(utterance.end))]"
                return "\(span) \(speakerName(utterance.speaker)): \(utterance.text)"
            }
            .joined(separator: "\n")
    }

    /// The map route's rendering: utterances derived within the chunk's OWN
    /// segments, each line carrying the utterance's first-constituent segment id
    /// so a cited id always resolves to a real persisted segment.
    ///
    /// A line is marked `(overlap)` only when EVERY constituent is in the
    /// chunk's overlap head — an utterance mixing overlap and new segments is new
    /// content the model must not skip.
    static func chunkTranscriptText(for chunk: TranscriptChunk) -> String {
        TranscriptUtterance.derive(from: chunk.segments)
            .map { utterance in
                let isOverlap = utterance.segmentIDs.allSatisfy { chunk.overlapSegmentIDs.contains($0) }
                let overlap = isOverlap ? "(overlap) " : ""
                let span = "[\(timestamp(utterance.start))-\(timestamp(utterance.end))]"
                let tags = "[\(speakerName(utterance.speaker))][\(utterance.channel.rawValue)]"
                return "\(overlap)\(span)\(tags)[id=\(utterance.id.uuidString)]: \(utterance.text)"
            }
            .joined(separator: "\n")
    }

    /// How a speaker is named TO THE MODEL.
    ///
    /// "Team", not `Speaker.displayName`'s "Others": the prompts state the
    /// convention in those words ("\"Team\" means teammates from system audio"),
    /// so the rendering and the rule have to agree. What the UI calls the same
    /// speaker is a separate decision and lives with the UI.
    static func speakerName(_ speaker: Speaker) -> String {
        switch speaker {
        case .me: return "You"
        case .teammates: return "Team"
        }
    }

    /// `m:ss`, or `h:mm:ss` once the meeting passes an hour.
    static func timestamp(_ value: TimeInterval) -> String {
        let total = Int(value)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
