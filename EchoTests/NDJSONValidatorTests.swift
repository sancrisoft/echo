//
//  NDJSONValidatorTests.swift
//  EchoTests
//
//  The validator is the structured-output gate that replaced the sampler-side
//  GBNF grammar (SPEC-01 decision B): nothing malformed may pass, and nothing
//  the old grammar allowed may be rejected.
//

import Foundation
import Testing
@testable import Echo

@Suite("NDJSONLineValidator")
struct NDJSONValidatorTests {

    @Test("valid protocol lines pass", arguments: [
        #"{"type":"short","text":"Team agreed to ship."}"#,
        #"{"type":"detailed","text":"A longer paragraph with \"quotes\" and a \\ backslash."}"#,
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
    ])
    func acceptsValidLines(_ line: String) {
        #expect(NDJSONLineValidator.isValid(line))
    }

    @Test("malformed lines are rejected", arguments: [
        "",
        "   ",
        "plain prose, not JSON",
        "```json",
        #"{"type":"short"}"#,                                        // missing text
        #"{"type":"short","text":null}"#,                            // null where string required
        #"{"type":"short","text":42}"#,                              // wrong type
        #"{"type":"unknown","text":"x"}"#,                           // unknown shape
        #"{"text":"no type"}"#,
        #"{"type":"decision","title":"x","details":"y"}"#,           // missing evidence
        #"{"type":"decision","title":"x","evidence":"id-1"}"#,       // evidence not an array
        #"{"type":"decision","title":"x","evidence":[1,2]}"#,        // evidence items not strings
        #"{"type":"decision","title":null,"evidence":["a"]}"#,       // required field null
        #"{"type":"action","task":"x","owner":7,"due":null,"evidence":["a"]}"#,  // owner wrong type
        #"{"type":"risk","risk":"x","details":{"a":1},"evidence":["a"]}"#,       // details wrong type
        #"["short","text"]"#,                                        // not an object
        #"{"type":"short","text":"unterminated"#,                    // broken JSON
    ])
    func rejectsMalformedLines(_ line: String) {
        #expect(!NDJSONLineValidator.isValid(line))
    }
}
