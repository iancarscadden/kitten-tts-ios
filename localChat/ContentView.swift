import Combine
import SwiftUI

struct ContentView: View {
    @State private var engine = KittenTTSEngine()
    @FocusState private var isTextEditorFocused: Bool
    @State private var inputText = "Destiny one is the best video game of all time. There is no denying it."
    @State private var selectedVoice = "Rosie"
    @State private var selectedModel: TTSModel = .mini
    @State private var speed: Float = 1.0
    @State private var generatedAudio: [Float]?
    @State private var statusMessage = ""
    @State private var isPlaying = false
    @State private var isStreaming = false
    @State private var streamChunkCount = 0
    @State private var streamStartTime: CFAbsoluteTime = 0
    @State private var timeToFirstChunk: Double? = nil
    @State private var streamTask: Task<Void, Never>?
    @State private var streamElapsed: Double = 0
    private let elapsedTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    header
                        .padding(.top, 8)
                        .padding(.bottom, 24)

                    VStack(spacing: 16) {
                        textInputCard
                        voiceAndModelCard
                        speedCard
                    }
                    .padding(.bottom, 24)

                    actionButtons
                        .padding(.bottom, 12)

                    statusBar
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                isTextEditorFocused = false
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if engine.state == .idle {
                engine.loadModel(selectedModel)
            }
        }
        .onReceive(elapsedTimer) { _ in
            if isStreaming {
                streamElapsed = CFAbsoluteTimeGetCurrent() - streamStartTime
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kitten TTS")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.surface)

                Text("On-device text to speech")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.neutral)
            }

            Spacer()

            engineStatusPill
        }
    }

    private var engineStatusPill: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Group {
                switch engine.state {
                case .idle:
                    Text("Idle")
                case .loading:
                    Text("Loading…")
                case .ready:
                    Text(engine.loadedModel?.displayName ?? "Ready")
                case .generating:
                    Text("Generating…")
                case .error:
                    Text("Error")
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.neutral)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.cardBg, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.darkAccent.opacity(0.5), lineWidth: 1))
    }

    private var statusColor: Color {
        switch engine.state {
        case .ready:                Color.primaryAccent
        case .loading, .generating: Color.orange
        case .error:                Color.red
        case .idle:                 Color.darkAccent
        }
    }

    // MARK: - Text Input Card

    private var textInputCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Text", systemImage: "text.alignleft")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.neutral)

            ZStack(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Enter text to be spoken aloud…")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.darkAccent)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $inputText)
                    .focused($isTextEditorFocused)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.surface)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 100, maxHeight: 140)
            }
        }
        .padding(14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isTextEditorFocused ? Color.primaryAccent.opacity(0.4) : Color.darkAccent.opacity(0.4),
                    lineWidth: 1
                )
        )
        .animation(.smooth(duration: 0.25), value: isTextEditorFocused)
    }

    // MARK: - Voice & Model Card

    private var voiceAndModelCard: some View {
        VStack(spacing: 0) {
            // Voice row
            VStack(alignment: .leading, spacing: 10) {
                Label("Voice", systemImage: "person.wave.2")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.neutral)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(KittenTTSEngine.voiceNames, id: \.self) { voice in
                            VoiceChip(
                                name: voice,
                                isSelected: selectedVoice == voice
                            ) {
                                withAnimation(.snappy(duration: 0.2)) {
                                    selectedVoice = voice
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.white
                        LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 12)
                    }
                )
            }
            .padding(14)

            Divider()
                .overlay(Color.darkAccent.opacity(0.4))

            // Model row
            VStack(alignment: .leading, spacing: 10) {
                Label("Model", systemImage: "cpu")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.neutral)

                HStack(spacing: 8) {
                    ForEach(TTSModel.allCases) { model in
                        ModelChip(
                            name: model.displayName,
                            isSelected: selectedModel == model
                        ) {
                            guard selectedModel != model else { return }
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedModel = model
                            }
                            generatedAudio = nil
                            statusMessage = ""
                            engine.loadModel(model)
                        }
                    }
                    Spacer()
                }
            }
            .padding(14)
        }
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.darkAccent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Speed Card

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Speed", systemImage: "gauge.with.needle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.neutral)

                Spacer()

                Text(String(format: "%.1fx", speed))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.primaryAccent)
            }

            Slider(value: $speed, in: 0.5...2.0, step: 0.1)
                .tint(Color.primaryAccent)
        }
        .padding(14)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.darkAccent.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Generate (batch)
                Button {
                    Task { await generateSpeech() }
                } label: {
                    HStack(spacing: 8) {
                        if engine.state == .generating && !isStreaming {
                            ProgressView()
                                .tint(Color.appBackground)
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "waveform")
                                .font(.system(size: 14, weight: .bold))
                        }
                        Text(engine.state == .generating && !isStreaming ? "Generating…" : "Generate")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        engine.state == .ready && !isStreaming
                            ? Color.primaryAccent
                            : Color.darkAccent.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(engine.state == .ready && !isStreaming ? Color.appBackground : Color.neutral)
                }
                .disabled(engine.state != .ready || isStreaming || inputText.trimmingCharacters(in: .whitespaces).isEmpty)

                // Stream (live)
                Button {
                    if isStreaming {
                        streamTask?.cancel()
                    } else {
                        streamTask = Task { await streamSpeech() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isStreaming {
                            StreamingBarsView()
                        } else {
                            Image(systemName: "dot.radiowaves.right")
                                .font(.system(size: 14, weight: .bold))
                        }
                        Text(isStreaming ? "Streaming…" : "Stream")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        isStreaming
                            ? Color.orange.opacity(0.85)
                            : (engine.state == .ready ? Color.secondaryAccent : Color.darkAccent.opacity(0.6)),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .foregroundStyle(engine.state == .ready || isStreaming ? .white : Color.neutral)
                }
                .disabled((engine.state != .ready && !isStreaming) || inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            // Play (batch result)
            if generatedAudio != nil {
                Button { playAudio() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 14, weight: .bold))
                        Text("Play Generated")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.secondaryAccent.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3), value: generatedAudio != nil)
        .animation(.snappy(duration: 0.2), value: isStreaming)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        VStack(spacing: 6) {
            if isStreaming {
                streamingStatusView
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.neutral)
                    .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: statusMessage)
        .animation(.smooth(duration: 0.2), value: isStreaming)
    }

    private var streamingStatusView: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange)

            if let ttfc = timeToFirstChunk {
                Text("first audio \(String(format: "%.2f", ttfc))s")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.neutral)
                Text("·")
                    .foregroundStyle(Color.darkAccent)
            }

            Text("\(streamChunkCount) chunk\(streamChunkCount == 1 ? "" : "s")")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.orange)

            Spacer()

            Text(String(format: "%.1fs", streamElapsed))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.neutral)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.cardBg, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3), lineWidth: 1))
    }

    // MARK: - Actions (logic unchanged)

    private func generateSpeech() async {
        generatedAudio = nil
        statusMessage = ""

        do {
            let t0 = CFAbsoluteTimeGetCurrent()
            let audio = try await engine.generate(
                text: inputText,
                voice: selectedVoice,
                speed: speed
            )
            let elapsed = CFAbsoluteTimeGetCurrent() - t0
            let duration = Float(audio.count) / Float(KittenTTSEngine.sampleRate)

            generatedAudio = audio
            statusMessage = String(
                format: "%.1fs audio in %.2fs",
                duration, elapsed
            )
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }

    private func playAudio() {
        guard let audio = generatedAudio else { return }
        do {
            try engine.play(samples: audio)
        } catch {
            statusMessage = "Playback error: \(error.localizedDescription)"
        }
    }

    private func streamSpeech() async {
        isStreaming = true
        streamChunkCount = 0
        streamElapsed = 0
        timeToFirstChunk = nil
        statusMessage = ""
        streamStartTime = CFAbsoluteTimeGetCurrent()

        let stream = engine.generateStreaming(
            text: inputText,
            voice: selectedVoice,
            speed: speed
        )

        do {
            for try await chunk in stream {
                if Task.isCancelled { break }
                if streamChunkCount == 0 {
                    timeToFirstChunk = CFAbsoluteTimeGetCurrent() - streamStartTime
                }
                streamChunkCount += 1
                try engine.scheduleChunk(chunk)
            }
            let totalElapsed = CFAbsoluteTimeGetCurrent() - streamStartTime
            if !Task.isCancelled {
                statusMessage = String(
                    format: "streamed %d chunks in %.2fs",
                    streamChunkCount, totalElapsed
                )
            }
        } catch is CancellationError {
            statusMessage = "stream cancelled"
        } catch {
            statusMessage = "Stream error: \(error.localizedDescription)"
        }

        isStreaming = false
    }
}

// MARK: - Streaming Bars Animation

private struct StreamingBarsView: View {
    @State private var animating = false

    private let barCount = 3
    private let barWidth: CGFloat = 2.5
    private let barMaxHeight: CGFloat = 11
    private let barMinHeight: CGFloat = 3

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.white)
                    .frame(width: barWidth, height: animating ? barMaxHeight : barMinHeight)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.13),
                        value: animating
                    )
            }
        }
        .frame(height: barMaxHeight)
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - Voice Chip

private struct VoiceChip: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.appBackground : Color.surface)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    isSelected ? Color.primaryAccent : Color.darkAccent.opacity(0.35),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : Color.darkAccent.opacity(0.5),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Model Chip

private struct ModelChip: View {
    let name: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12, weight: isSelected ? .bold : .medium))
                .foregroundStyle(isSelected ? Color.white : Color.neutral)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isSelected ? Color.secondaryAccent : Color.clear,
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(
                        isSelected ? Color.clear : Color.darkAccent.opacity(0.5),
                        lineWidth: 1
                    )
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
}
