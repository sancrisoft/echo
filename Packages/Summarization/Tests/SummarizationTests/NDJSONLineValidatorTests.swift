//
//  NDJSONLineValidatorTests.swift
//  SummarizationTests
//
//  The validator is the structured-output gate that replaced the sampler-side
//  GBNF grammar: nothing malformed may pass, and nothing the old grammar
//  allowed may be rejected. Pure tables — no engine, no model.
//

import Foundation
import Summarization
import Testing

@Suite("NDJSONLineValidator")
struct NDJSONLineValidatorTests {

    @Test(
        "valid protocol lines pass",
        arguments: [
            #"{"type":"short","text":"Team agreed to ship."}"#,
            #"{"type":"detailed","text":"A longer paragraph with \"quotes\" and a \\ backslash."}"#,
            #"{"type":"chunknote","text":"What this part of the meeting covered."}"#,
            #"{"type":"decision","title":"Ship v2","details":"After QA","evidence":["abc-123"]}"#,
            #"{"type":"decision","title":"Ship v2","details":null,"evidence":[]}"#,
            #"{"type":"action","task":"Write docs","owner":null,"due":null,"evidence":["id-1"]}"#,
            #"{"type":"action","task":"Write docs","owner":"You","due":"Friday","evidence":["id-1","id-2"]}"#,
            // Nullable fields may be omitted entirely (prompt-driven models do this).
            #"{"type":"question","question":"Which region?","evidence":["id-9"]}"#,
            #"{"type":"risk","risk":"Vendor delay","details":"Contract unsigned","evidence":["id-3"]}"#,
            // The model often writes the string "null"; the accumulator maps it to nil.
            #"{"type":"action","task":"Follow up","owner":"null","due":"null","evidence":["id-4"]}"#,
            "  {\"type\":\"short\",\"text\":\"leading whitespace tolerated\"}  ",
        ]
    )
    func acceptsValidLines(_ line: String) {
        #expect(NDJSONLineValidator.isValid(line))
    }

    @Test(
        "malformed lines are rejected",
        arguments: [
            "",
            "   ",
            "plain prose, not JSON",
            "```json",
            // Missing text.
            #"{"type":"short"}"#,
            // Null where a string is required.
            #"{"type":"short","text":null}"#,
            // Wrong type.
            #"{"type":"short","text":42}"#,
            // Unknown shape.
            #"{"type":"unknown","text":"x"}"#,
            #"{"text":"no type"}"#,
            // Missing evidence.
            #"{"type":"decision","title":"x","details":"y"}"#,
            // Evidence is not an array.
            #"{"type":"decision","title":"x","evidence":"id-1"}"#,
            // Evidence items are not strings.
            #"{"type":"decision","title":"x","evidence":[1,2]}"#,
            // Required field null.
            #"{"type":"decision","title":null,"evidence":["a"]}"#,
            // Owner is the wrong type.
            #"{"type":"action","task":"x","owner":7,"due":null,"evidence":["a"]}"#,
            // Details are the wrong type.
            #"{"type":"risk","risk":"x","details":{"a":1},"evidence":["a"]}"#,
            // Not an object.
            #"["short","text"]"#,
            // Broken JSON.
            #"{"type":"short","text":"unterminated"#,
        ]
    )
    func rejectsMalformedLines(_ line: String) {
        #expect(!NDJSONLineValidator.isValid(line))
    }
}
