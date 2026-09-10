//
//  SummaryLanguage.swift
//  Summarization
//
//  Which language the notes must be written in, decided from the transcript.
//
//  This exists because of a field bug, and the shape of the fix is the shape of
//  the bug. Every piece of scaffolding around the model is English — the rules,
//  the examples, the closing reminder that measurably dominates behaviour — so a
//  fully Spanish meeting came out as an English summary. One generic "write in
//  the dominant language of the transcript" line in the system prompt cannot
//  outweigh that on a 4B model: it measured 2/2 failures. The answer is to
//  detect the language here and then state it EXPLICITLY, twice, in words the
//  model cannot generalize away (see `SummaryPrompts`).
//

import EchoCore
import Foundation
import NaturalLanguage

enum SummaryLanguage {

    /// Characters of transcript fed to the recognizer.
    static let sampleBudget = 3_000

    /// How many segments the sample is spread over.
    static let sampleSegments = 60

    /// Below this confidence the answer is nil rather than a guess.
    ///
    /// A garbled or too-short sample must not produce a coin-flip label: the
    /// answer steers the language of the whole summary, so being unsure is
    /// strictly better than being wrong.
    static let confidenceFloor = 0.6

    /// The transcript's dominant language as an ENGLISH language name
    /// ("Spanish", "English", "Portuguese"), or nil when there is no confident
    /// answer — in which case the prompts keep their generic wording.
    ///
    /// The sample is a STRIDE across the whole meeting, not its head: a meeting
    /// that opens with an English greeting and then runs in Spanish must not be
    /// labelled English. Pure and static, so it is tested directly.
    ///
    /// The name is English even when the language is not, because it is
    /// interpolated into English prompt sentences.
    static func dominantName(of segments: [TranscriptSegment]) -> String? {
        let texts = segments.map(\.text).filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }

        let stride = max(1, texts.count / sampleSegments)
        var sample = ""
        var index = 0
        while index < texts.count && sample.count < sampleBudget {
            sample += texts[index]
            sample += "\n"
            index += stride
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= confidenceFloor else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: language.rawValue)
    }
}
