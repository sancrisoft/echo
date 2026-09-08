---
name: echo-summarization
description: Echo's local summary pipeline and its measured prompt invariants — `SummarizationPipeline`, `SummaryMapReduce`, `MLXTextEngine`, `SummaryModelManager`, `MeetingSummary`, `summary.md`, size routing, evidence grounding, owner/due-date invention, output language, and MLX memory behaviour.
---

## Grounding rules that are not negotiable

The summary is grounded in the transcript. Never invent decisions, action-item owners, due dates or risks; an unclear owner or date stays empty/null (`AGENTS.md`, and the prompts enforce it).

The owner trap is the measured one. **Mention ≠ ownership**: name an owner only when that person took the task — said they would do it, or accepted it when asked. Whoever merely mentioned or requested it is not the owner and the item ships with no name. Notion-parity fixtures went 2/4 → **4/4 clean** once the rule carried an explicit ownerless inline example, because the `- [ ] Name to <verb>` template itself was demanding a name (`SummarizationPipeline.swift:611-641`).

In the deterministic merge, a duplicate may **fill in** a null `owner`/`due` but null never overwrites a concrete value (`SummaryMapReduce.swift:138-139`, `:173-175`).

Evidence is executable, not decorative: every cited ID is filtered against the real segment IDs in scope and an item left with no valid evidence is **dropped and logged** (`SummarizationPipeline.swift:24-25`, `:930-931`).

## The closing reminder slot is zero-sum

One reminder is appended after the transcript (single-pass) and after the material (reduce), because a small model weighs instructions most at the very end of context. The same omission rule sitting only in the far-away system prompt measured **6/6 small-talk leaks**. But that slot competes with itself: a small-talk-only closer regressed the owner trap **4/4 → 0/2**. So `workNotesReminder` carries *both* probabilistic traps, and the language sentence is **appended** after them, never replacing anything (`SummarizationPipeline.swift:645-666`).

Related prompt-engineering facts, all measured:
- Load-bearing phrases are pinned by `SummarizationPipelineStreamTests` and `SummaryMapReduceTests` — `"### Action Items"`, `"never invent an owner or a due date"`, `"dominant language of the transcript"`, `"no code fences"`, `"never write an empty section"`, `"no section, no mention"`, `"sweep the whole transcript for commitments"`, `"naming someone who did not take the task is an error"`. Reword freely around them; keep them intact.
- A pinned phrase must not wrap across lines inside a Swift multiline literal — build pinned constants by concatenation.
- Collateral wording edits regress unrelated traps (one iteration rewrote trigger cues and dropped the owner trap to 1/4). Measure every prompt change against the parity fixtures; do not eyeball it.
- The small-talk filter is still an open gap on a 4B model, recorded honestly as `withKnownIssue("small-talk filter not yet reliable on the 4B model — tracked gap", isIntermittent: true)` in `SummaryNotionParityTests.swift:176`. Do not "fix" that test by deleting the known issue.
- `adaptiveSharedRules` is shared **verbatim** by the single-pass and reduce prompts so the two routes' documents cannot drift.

## Output language is set explicitly, twice

An all-English prompt scaffolding pulls a 4B model into English output: a fully Spanish field meeting produced an English summary, and a generic "dominant language of the transcript" rule measured 2/2 failures. `dominantLanguageName` runs `NLLanguageRecognizer` **once** per generation over a stride sample of ~3000 chars spread across the whole meeting (never just the head, or an English greeting mislabels the meeting), with a **0.6 confidence floor**; `nil` keeps the generic prompts. The answer is injected into single-pass framing, the map chunknote line, the reduce prompt, and the closing reminder (`SummarizationPipeline.swift:106-140`). The `### Action Items` anchor stays English by design.

## Adaptive document, not a fixed schema

Notes are one Markdown document. `### Action Items` is the single fixed anchor when commitments exist; everything after is one `###` section per distinct work topic with a title **specific to the content** ("Audio Bug: Wireless Headphone Frequency Issue"), never a generic bucket. Category sections appear only when the meeting earns them. Never an empty section, a `(none)` placeholder, or padding. Length follows information density, not transcript length. Preserve specifics exactly — numbers, thresholds, versions, product names, root-cause chains. Omit social small talk entirely, *no section, no mention*, unless an outside event changed the work. When a passage is garbled, hedge ("likely", "apparently") rather than inventing or silently dropping the topic.

`summary.md` **is** the store (ADR-028), not a mirror: writes persist exactly `MeetingSummary.resolvedMarkdown`; reads prefer the md with a tolerant `summary.json` fallback for unmigrated folders, and a launch-time idempotent `migrateLegacySummaries()` writes the md before deleting the json (`MeetingStore.swift:639-680`, `:817-827`). Do not reintroduce the json as authoritative.

## Size routing and sampling

- `estimatedTokens(of:)` (`ceil(scalars/4)`, min 1 per non-empty segment) ≤ `singlePassBudget` **8_000** → single pass; above → map-reduce (`SummarizationPipeline.swift:47`, `:93`). Routing is on transcript size alone, independent of prompt overhead, so the boundary is stable and matches chunking.
- Long route: NDJSON `mapChunk` per chunk → **deterministic Swift** `mergeMapResults` (no LLM) → one markdown reduce. Maps run **in series** — one engine, bounded memory. An empty reduce degrades to facts-only. `SummaryLimits.maxItemsPerSection` = 20.
- `GenerationParams.markdownSummary`: temperature 0.4, topP 0.95, maxTokens 4096, repetitionPenalty 1.05, frequency and presence penalties **0.0** (`TextGenerating.swift:52-59`). Do not reuse the plain defaults (0.3/0.9/3072/1.1/0.6/0.3) on a markdown document: those penalties exist to break degenerate NDJSON loops and on free markdown they punish every `- [ ] ` checkbox prefix and every recurrence of an entity name, so a long document degrades as they accumulate. The plain default stays for the NDJSON map phase and the row caption.

## MLX has no memory ceiling — bound by admission

`Memory.memoryLimit` is only a GC threshold: exceeding it releases cached buffers and then **allocates anyway** — no wait, no spill, no throw (the Swift doc comment describes behaviour the vendored C++ no longer implements). The wired limit defaults to 0 and raising it would only make Echo's pages un-evictable. MLX's default error handler **prints and exits the process**, so an allocation failure is a hard exit, not a catchable error. Never reach for `GPU.set(memoryLimit:)` or the wired limit as a cap; decide *before* loading whether the work fits, and make the work degradable. The one memory knob actually used is `MLX.GPU.set(cacheLimit: 20 * 1024 * 1024)` at load (`SummaryModelManager.swift:400`).

Weights (`mlx-community/Qwen3.5-4B-OptiQ-4bit`, ~3.3 GB) load only for active summary work and are released **60 s** after the last use (`summaryModelIdleTimeout`) — long enough to span a regenerate or the backfill loop.

## Prompt templating is hand-rolled on purpose

`MLXTextEngine.chatMLPrompt` builds the ChatML turns itself, transcribed from the model repo's `chat_template.jinja`: `<|im_start|>role\n…<|im_end|>\n` per turn, **no BOS** (Qwen defines none), and with thinking disabled the generation prompt pre-fills an empty `<think>` block. Tokenize with `addSpecialTokens: false` — letting the tokenizer inject specials corrupts the prompt. The vendored tokenizer surface exposes no `applyChatTemplate`, and chat templates have historically folded or dropped the system prompt, so an assertion checks the system prompt survived templating. Generation stops on the tokenizer's declared `<|im_end|>` (this repo's `generation_config.json` carries only sampling params). Structured output is a **validator fallback** (`NDJSONLineValidator` gates every line plus one full retry), not constrained decoding.
