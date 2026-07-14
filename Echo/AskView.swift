//
//  AskView.swift
//  Echo
//
//  The "Ask" tab of a saved meeting's detail (SPEC-06): ask a question, get an
//  answer grounded ONLY in retrieved transcript chunks, with `[m:ss]` citations.
//  The Q&A history is in-memory per view — closing the meeting forgets it.
//
//  The heavy lifting lives in `QAPipeline` (retrieval → relevance floor →
//  grounded streamed generation). This view is a thin driver over
//  `controller.qaPipeline`: it manages the input, the transcript of turns, and
//  the download/indexing/streaming states, and reuses the recording
//  controller's model managers (no duplicated model state — SPEC-06 §3.5).
//
//  Concurrency (SPEC-06 §6): only one question runs at a time; asking a new one
//  CANCELS the in-flight generation (terminating the stream cancels the
//  underlying MLX generation) and starts the new answer.
//

import SwiftUI
import Observation

/// One question and its (growing) answer. `phase` is the transient status line
/// shown while the models load / the meeting indexes / the answer streams.
private struct QATurn: Identifiable {
    let id = UUID()
    let question: String
    var answer: QAAnswer?
    var phase: String?
    var errorText: String?
}

@MainActor
@Observable
private final class AskViewModel {

    var draft: String = ""
    private(set) var turns: [QATurn] = []
    private(set) var isBusy = false
    /// Whether both Q&A models are on disk. Nil until the first check completes
    /// (so the view doesn't flash the CTA before we know).
    private(set) var modelsReady: Bool?
    /// Progress line for the download CTA (distinct from a turn's `phase`).
    private(set) var downloadPhase: String?

    /// Rejects stale async updates after a newer question (or download) started.
    private var generation = 0
    private var task: Task<Void, Never>?

    func refreshModelsReady(controller: RecordingController) async {
        modelsReady = await controller.qaModelsCached()
    }

    func downloadModels(controller: RecordingController) {
        guard isBusy == false else { return }
        generation += 1
        let gen = generation
        isBusy = true
        downloadPhase = "Preparing…"
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String, Double) -> Void = { phase, fraction in
                Task { @MainActor in
                    guard self.generation == gen else { return }
                    self.downloadPhase = Self.progressLine(phase, fraction)
                }
            }
            do {
                try await controller.ensureQAModelsReady(progress: progress)
                guard self.generation == gen else { return }
                self.modelsReady = true
            } catch {
                guard self.generation == gen else { return }
                self.downloadPhase = error.localizedDescription
            }
            guard self.generation == gen else { return }
            self.isBusy = false
            self.downloadPhase = nil
        }
    }

    func ask(meetingID: UUID, controller: RecordingController) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        // A new question supersedes any in-flight one: cancel it (which cancels
        // the underlying generation) and ignore its late updates via `gen`.
        task?.cancel()
        generation += 1
        let gen = generation

        draft = ""
        isBusy = true
        let index = turns.count
        turns.append(QATurn(question: question, answer: nil, phase: "Thinking…"))

        let pipeline = controller.qaPipeline
        task = Task { [weak self] in
            guard let self else { return }
            let progress: @Sendable (String, Double) -> Void = { phase, fraction in
                Task { @MainActor in
                    guard self.generation == gen, self.turns.indices.contains(index) else { return }
                    self.turns[index].phase = Self.progressLine(phase, fraction)
                }
            }
            do {
                for try await answer in await pipeline.answer(
                    question: question, meetingID: meetingID, progress: progress
                ) {
                    guard self.generation == gen, self.turns.indices.contains(index) else { return }
                    self.turns[index].answer = answer
                    self.turns[index].phase = nil
                }
            } catch is CancellationError {
                // Superseded by a newer question — leave the partial answer as-is.
                return
            } catch {
                guard self.generation == gen, self.turns.indices.contains(index) else { return }
                self.turns[index].errorText = error.localizedDescription
                self.turns[index].phase = nil
            }
            guard self.generation == gen else { return }
            self.isBusy = false
        }
    }

    private static func progressLine(_ phase: String, _ fraction: Double) -> String {
        // Download/index phases carry a fraction worth showing; the load/stream
        // phases don't. Only append a percentage while it is meaningful.
        if fraction > 0, fraction < 1 {
            return "\(phase) \(Int(fraction * 100))%"
        }
        return phase
    }
}

struct AskView: View {
    let meetingID: UUID
    @Environment(RecordingController.self) private var controller
    @State private var model = AskViewModel()

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            inputBar
        }
        .task(id: meetingID) {
            await model.refreshModelsReady(controller: controller)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.modelsReady {
        case .none:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .some(false):
            modelDownloadCTA
        case .some(true):
            if model.turns.isEmpty {
                ContentUnavailableView(
                    "Ask anything about this meeting.",
                    systemImage: "questionmark.bubble",
                    description: Text("Answers come only from this meeting's transcript, with timestamps.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                conversation
            }
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(model.turns) { turn in
                        QATurnRow(turn: turn)
                            .id(turn.id)
                    }
                }
                .padding()
            }
            .onChange(of: model.turns.last?.id) { _, last in
                guard let last else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
    }

    private var modelDownloadCTA: some View {
        VStack(spacing: 18) {
            ContentUnavailableView(
                "Models needed to answer",
                systemImage: "arrow.down.circle",
                description: Text("Answering runs entirely on-device. The answer model and the embedding model download once.")
            )
            if let phase = model.downloadPhase {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(phase)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    model.downloadModels(controller: controller)
                } label: {
                    Label("Download models", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about this meeting…", text: Binding(
                get: { model.draft },
                set: { model.draft = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit(submit)
            .disabled(!canAsk)

            Button(action: submit) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                }
            }
            .buttonStyle(.plain)
            .disabled(!canAsk || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
    }

    private var canAsk: Bool {
        model.modelsReady == true && !model.isBusy
    }

    private func submit() {
        guard canAsk else { return }
        model.ask(meetingID: meetingID, controller: controller)
    }
}

// MARK: - Turn row

private struct QATurnRow: View {
    let turn: QATurn

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.fill")
                    .foregroundStyle(.blue)
                    .padding(.top, 2)
                Text(turn.question)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
            }

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.purple)
                    .padding(.top, 2)
                answerBody
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var answerBody: some View {
        if let errorText = turn.errorText {
            Text(errorText)
                .font(.body)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        } else if let answer = turn.answer, !answer.text.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(answer.text)
                    .font(.body)
                    .foregroundStyle(answer.isRefusal ? .secondary : .primary)
                    .textSelection(.enabled)
                if !answer.citations.isEmpty {
                    Text(Self.citationsLine(answer.citations))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(turn.phase ?? "Thinking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func citationsLine(_ citations: [QACitation]) -> String {
        "Sources: " + citations.map { "[\(timestamp($0.start))–\(timestamp($0.end))]" }.joined(separator: " ")
    }

    private static func timestamp(_ value: TimeInterval) -> String {
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

// MARK: - Unavailable placeholder (live session / recording)

/// Shown in the Ask tab for the live session and while recording: Q&A needs the
/// finished, saved transcript (SPEC-06 §3.4).
struct AskUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Ask",
            systemImage: "questionmark.bubble",
            description: Text(message)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
