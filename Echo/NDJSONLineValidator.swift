//
//  NDJSONLineValidator.swift
//  Echo
//
//  Structured-output guarantee for the summary protocol (SPEC-01 §5 paso 4).
//
//  The retired server runtime enforced the NDJSON shape with a GBNF grammar at the
//  sampler. Swift/MLX constrained decoding was evaluated (2026-07):
//  mlx-swift-structured (XGrammar-backed) exists and could express the
//  protocol as EBNF, but integrating it means a second tokenizer stack
//  (it derives its vocab from swift-transformers while generation runs on the
//  ArgmaxCore bridge), a vendored C++ build, and floating dependency ranges —
//  the spec's "integración frágil" case. So the sanctioned fallback applies:
//  the system prompt still specifies the protocol, and this validator gates
//  every completed line against the per-type schema BEFORE it reaches the
//  accumulator, so no malformed line can reach the UI. The pipeline retries
//  the whole generation once if a stream ends with no valid short/detailed.
//
//  The schema mirrors the retired GBNF exactly: fixed required fields per
//  type, nullable fields are string-or-null, evidence is an array of strings.
//

import Foundation

nonisolated enum NDJSONLineValidator {

    /// Whether one completed line is a well-formed protocol object.
    /// Empty/whitespace lines are invalid (the pipeline just skips them).
    static func isValid(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmed.isEmpty,
            let data = trimmed.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data),
            let object = parsed as? [String: Any],
            let type = object["type"] as? String
        else {
            return false
        }

        switch type {
        case "short", "detailed":
            return isString(object["text"])
        case "decision":
            return isString(object["title"])
                && isNullableString(object["details"])
                && isStringArray(object["evidence"])
        case "action":
            return isString(object["task"])
                && isNullableString(object["owner"])
                && isNullableString(object["due"])
                && isStringArray(object["evidence"])
        case "question":
            return isString(object["question"])
                && isNullableString(object["context"])
                && isStringArray(object["evidence"])
        case "risk":
            return isString(object["risk"])
                && isNullableString(object["details"])
                && isStringArray(object["evidence"])
        default:
            return false
        }
    }

    /// Required string field: must be present and a string.
    private static func isString(_ value: Any?) -> Bool {
        value is String
    }

    /// Nullable field: may be absent, JSON null, or a string — anything else
    /// (number, object, array) is malformed.
    private static func isNullableString(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }

    /// Evidence: must be present and an array whose elements are all strings
    /// (empty is allowed — the grammar allowed it; grounding is judged by the
    /// prompt rules, not the parser).
    private static func isStringArray(_ value: Any?) -> Bool {
        guard let array = value as? [Any] else { return false }
        return array.allSatisfy { $0 is String }
    }
}
