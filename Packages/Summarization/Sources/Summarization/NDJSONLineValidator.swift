//
//  NDJSONLineValidator.swift
//  Summarization
//
//  The structured-output guarantee for the map phase's NDJSON protocol.
//
//  The retired server runtime enforced the shape with a GBNF grammar at the
//  sampler. Swift/MLX constrained decoding was evaluated (2026-07):
//  mlx-swift-structured (XGrammar-backed) could express the protocol as EBNF,
//  but integrating it means a second tokenizer stack — it derives its vocab
//  from swift-transformers while generation runs on the MLX bridge — a vendored
//  C++ build and floating dependency ranges. So the fallback applies: the
//  system prompt specifies the protocol, and this validator gates every
//  COMPLETED line against the per-type schema before it reaches the
//  accumulator, so no malformed line can reach a document.
//
//  The schema mirrors the retired grammar exactly: fixed required fields per
//  type, nullable fields are string-or-null, evidence is an array of strings.
//
//  Two properties callers depend on. It never throws — a parse failure is
//  `false`, which is why the `try?` below is the whole error path. And it is
//  only ever asked about a line that is already complete: the pipeline splits
//  on newlines and flushes one trailing object, so there is no such thing here
//  as a partially-arrived line that was valid a moment ago.
//

import Foundation

public enum NDJSONLineValidator {

    /// Whether one completed line is a well-formed protocol object.
    /// Empty and whitespace-only lines are invalid; the pipeline skips them.
    public static func isValid(_ line: String) -> Bool {
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
            // The retired prose protocol. Still accepted, and deliberately so:
            // this validator is WIDER than any live phase. `AllowedShapes` is
            // what decides which well-formed shapes a phase contributes, so a
            // stray line of a retired type is ignored downstream instead of
            // being rejected here — and a model that emits one has not
            // "produced malformed output".
            return isString(object["text"])
        case "chunknote":
            // The map phase's per-part note: text only, no evidence.
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
    /// (number, object, array) is malformed. Absence is allowed because
    /// prompt-driven models omit fields they have nothing for.
    private static func isNullableString(_ value: Any?) -> Bool {
        value == nil || value is NSNull || value is String
    }

    /// Evidence: must be present and an array whose elements are all strings.
    /// An empty array is well-formed — the grammar allowed it, and whether a
    /// fact is grounded is decided by the evidence filter, not by the parser.
    private static func isStringArray(_ value: Any?) -> Bool {
        guard let array = value as? [Any] else { return false }
        return array.allSatisfy { $0 is String }
    }
}
