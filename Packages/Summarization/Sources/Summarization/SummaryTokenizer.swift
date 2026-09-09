//
//  SummaryTokenizer.swift
//  Summarization
//
//  Bridges swift-transformers' tokenizer into the protocol MLX's model factory
//  expects. Two libraries, two same-named `Tokenizer` protocols, one real
//  tokenizer underneath.
//
//  Chat templating is deliberately unsupported. `MLXTextEngine` builds the turn
//  format itself, in code, so a template the two stacks might disagree about
//  never enters the picture — and `applyChatTemplate` throwing is how that
//  choice is enforced rather than merely documented. Anything that tries to
//  template through this seam fails loudly instead of silently producing a
//  prompt with a different shape than the one that was measured.
//

import Foundation
import MLXLMCommon
import Tokenizers

/// Loads the real tokenizer from a snapshot directory and wraps it.
///
/// Internal, but reached directly by the acceptance suite: pinning that the
/// ChatML markers encode as the single tokens the model declares is the one
/// check that catches a repo publishing a different vocabulary.
struct SummaryTokenizerLoader: TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        BridgedTokenizer(wrapped: try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct BridgedTokenizer: MLXLMCommon.Tokenizer {

    let wrapped: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        wrapped.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        wrapped.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        wrapped.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        wrapped.convertIdToToken(id)
    }

    var bosToken: String? { wrapped.bosToken }
    var eosToken: String? { wrapped.eosToken }
    var unknownToken: String? { wrapped.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        throw MLXLMCommon.TokenizerError.missingChatTemplate
    }
}
