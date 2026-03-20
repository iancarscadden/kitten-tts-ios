import Foundation
import AVFoundation
import Observation
import OnnxRuntimeBindings

// MARK: - Model Configuration

nonisolated enum TTSModel: String, CaseIterable, Identifiable, Sendable {
    case nano, micro, mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nano: return "Nano (15M)"
        case .micro: return "Micro (40M)"
        case .mini: return "Mini (80M)"
        }
    }

    var modelFileName: String { "kitten_tts_\(rawValue)_v0_8" }
    var voicesFileName: String { "voices_\(rawValue)" }

    var speedPriors: [String: Float] {
        guard self == .nano else { return [:] }
        return [
            "Bella": 0.8, "Jasper": 0.8,
            "Luna": 0.8,  "Bruno": 0.8,
            "Rosie": 0.8, "Hugo": 0.9,
            "Kiki": 0.8,  "Leo": 0.8,
        ]
    }
}

// MARK: - Engine State

nonisolated enum EngineState: Equatable, Sendable {
    case idle, loading, ready, generating, error(String)
}

// MARK: - Errors

nonisolated enum TTSError: Error, LocalizedError, Sendable {
    case modelNotFound(String)
    case voicesNotFound
    case notReady
    case voiceNotFound(String)
    case inferenceError(String)
    case espeakInitFailed
    case phonemizationFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let n): "Model '\(n)' not found in bundle"
        case .voicesNotFound:       "Voices file not found in bundle"
        case .notReady:             "Engine not ready — load a model first"
        case .voiceNotFound(let v): "Voice '\(v)' not found"
        case .inferenceError(let m):"Inference error: \(m)"
        case .espeakInitFailed:     "Failed to initialize espeak-ng"
        case .phonemizationFailed:  "Failed to phonemize text"
        }
    }
}

// MARK: - Engine

@Observable
final class KittenTTSEngine {

    var state: EngineState = .idle
    var loadedModel: TTSModel?

    @ObservationIgnored private var session: ORTSession?
    @ObservationIgnored private var env: ORTEnv?
    @ObservationIgnored private var voices: [String: [[Float]]] = [:]
    @ObservationIgnored private var espeakReady = false
    @ObservationIgnored private let audioEngine = AVAudioEngine()
    @ObservationIgnored private let playerNode = AVAudioPlayerNode()

    static nonisolated let sampleRate = 24000
    static nonisolated let voiceNames = [
        "Rosie", "Bella", "Jasper", "Luna",
        "Bruno", "Hugo",  "Kiki",   "Leo",
    ]

    // MARK: Lifecycle

    init() {
        audioEngine.attach(playerNode)
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )!
        audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: fmt)
    }

    // MARK: Model Loading

    func loadModel(_ model: TTSModel) {
        state = .loading
        loadedModel = nil
        session = nil

        Task.detached { [weak self] in
            do {
                // ── Locate model files ──
                guard let modelPath = Bundle.main.path(
                    forResource: model.modelFileName, ofType: "onnx"
                ) else { throw TTSError.modelNotFound(model.displayName) }

                guard let voicesURL = Bundle.main.url(
                    forResource: model.voicesFileName, withExtension: "json"
                ) else { throw TTSError.voicesNotFound }

                // ── Create ONNX session ──
                let env = try ORTEnv(loggingLevel: .warning)
                let opts = try ORTSessionOptions()
                try opts.setLogSeverityLevel(.warning)
                try opts.setIntraOpNumThreads(2)
                let session = try ORTSession(
                    env: env, modelPath: modelPath, sessionOptions: opts
                )

                // ── Parse voice embeddings ──
                let data = try Data(contentsOf: voicesURL)
                let json = try JSONSerialization.jsonObject(with: data)
                    as! [String: [[Double]]]
                var voices: [String: [[Float]]] = [:]
                for (name, positions) in json {
                    voices[name] = positions.map { $0.map(Float.init) }
                }

                // ── Initialize espeak-ng ──
                let dataDir = try Self.prepareEspeakData()
                let initResult = espeak_bridge_init(dataDir)
                guard initResult == 0 else { throw TTSError.espeakInitFailed }

                await MainActor.run {
                    self?.env = env
                    self?.session = session
                    self?.voices = voices
                    self?.espeakReady = true
                    self?.loadedModel = model
                    self?.state = .ready
                }
            } catch {
                await MainActor.run {
                    self?.state = .error(error.localizedDescription)
                }
            }
        }
    }

    // MARK: Generation

    func generate(
        text: String,
        voice: String,
        speed: Float = 1.0
    ) async throws -> [Float] {
        guard let session, espeakReady else { throw TTSError.notReady }
        guard let voicePositions = voices[voice] else {
            throw TTSError.voiceNotFound(voice)
        }

        state = .generating

        // 1. Chunk → phonemize (espeak) → tokenize
        let chunks = Self.chunkText(text)
        var prepared: [(tokens: [Int64], refId: Int)] = []

        for chunk in chunks {
            let cleaned = Self.ensurePunctuation(chunk)

            // Phonemize with punctuation preservation (matches Python phonemizer)
            let phonemes = Self.phonemizePreservingPunctuation(cleaned)

            let normalized = Self.basicEnglishTokenize(phonemes)
            var tokens = Self.phonemesToTokens(normalized)

            // [pad] + tokens + [end-of-text ‹…›=10] + [pad]
            tokens.insert(0, at: 0)
            tokens.append(10)
            tokens.append(0)

            let refId = min(cleaned.count, voicePositions.count - 1)
            prepared.append((tokens, refId))
        }

        // Speed prior
        let effectiveSpeed: Float
        if let prior = loadedModel?.speedPriors[voice] {
            effectiveSpeed = speed * prior
        } else {
            effectiveSpeed = speed
        }

        // 2. ONNX inference on background thread
        let audio: [Float] = try await Task.detached {
            var all: [Float] = []
            for chunk in prepared {
                let samples = try Self.runInference(
                    session: session,
                    tokens: chunk.tokens,
                    style: voicePositions[chunk.refId],
                    speed: effectiveSpeed
                )
                all.append(contentsOf: samples)
            }
            return all
        }.value

        state = .ready
        return audio
    }

    // MARK: Streaming Generation

    /// Yields audio chunks as each text chunk finishes inference, enabling
    /// playback to begin before the full text has been synthesised.
    func generateStreaming(
        text: String,
        voice: String,
        speed: Float = 1.0
    ) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { continuation in
            Task.detached { [weak self] in
                guard let self else { continuation.finish(); return }
                guard let session = await self.session, await self.espeakReady else {
                    continuation.finish(throwing: TTSError.notReady)
                    return
                }
                guard let voicePositions = await self.voices[voice] else {
                    continuation.finish(throwing: TTSError.voiceNotFound(voice))
                    return
                }

                await MainActor.run { self.state = .generating }

                let effectiveSpeed: Float
                if let prior = await self.loadedModel?.speedPriors[voice] {
                    effectiveSpeed = speed * prior
                } else {
                    effectiveSpeed = speed
                }

                let chunks = Self.chunkText(text)
                do {
                    for chunk in chunks {
                        let cleaned = Self.ensurePunctuation(chunk)
                        let phonemes = Self.phonemizePreservingPunctuation(cleaned)
                        let normalized = Self.basicEnglishTokenize(phonemes)
                        var tokens = Self.phonemesToTokens(normalized)
                        tokens.insert(0, at: 0)
                        tokens.append(10)
                        tokens.append(0)

                        let refId = min(cleaned.count, voicePositions.count - 1)
                        let samples = try Self.runInference(
                            session: session,
                            tokens: tokens,
                            style: voicePositions[refId],
                            speed: effectiveSpeed
                        )
                        continuation.yield(samples)
                    }
                    await MainActor.run { self.state = .ready }
                    continuation.finish()
                } catch {
                    await MainActor.run { self.state = .error(error.localizedDescription) }
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: Playback

    /// Schedules a chunk for immediate playback without stopping the player.
    /// Call this for each chunk yielded by generateStreaming() — buffers queue
    /// back-to-back with no gap between chunks.
    func scheduleChunk(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        if !audioEngine.isRunning {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            try audioEngine.start()
        }
        playerNode.scheduleBuffer(buf)
        if !playerNode.isPlaying { playerNode.play() }
    }

    func play(samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        playerNode.stop()

        let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(Self.sampleRate),
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)

        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        if !audioEngine.isRunning { try audioEngine.start() }

        playerNode.scheduleBuffer(buf)
        playerNode.play()
    }

    func stopPlayback() { playerNode.stop() }
}

// MARK: - espeak-ng Data Setup

extension KittenTTSEngine {

    /// Build the espeak-ng-data directory in Caches with the correct structure.
    /// Xcode's synchronized group flattens files and skips extensionless files,
    /// so we write the language definitions from code.
    nonisolated private static func prepareEspeakData() throws -> String {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dest = caches.appendingPathComponent("espeak-ng-data", isDirectory: true)

        // If already prepared, reuse it
        if fm.fileExists(atPath: dest.appendingPathComponent("phontab").path)
            && fm.fileExists(atPath: dest.appendingPathComponent("lang/gmw/en-US").path) {
            return dest.path
        }

        try? fm.removeItem(at: dest)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // ── Core binary files ──
        let coreFiles = [
            "phontab", "phondata", "phondata-manifest",
            "phonindex", "intonations", "en_dict",
        ]

        let bundle = Bundle.main
        for file in coreFiles {
            if let src = bundle.url(forResource: file, withExtension: nil) {
                try fm.copyItem(at: src, to: dest.appendingPathComponent(file))
            } else if let src = bundle.url(
                forResource: file, withExtension: nil, subdirectory: "espeak-ng-data"
            ) {
                try fm.copyItem(at: src, to: dest.appendingPathComponent(file))
            } else {
                print("[espeak] WARNING: missing data file: \(file)")
            }
        }

        // ── Language definitions ──
        // These have no file extension so Xcode won't bundle them.
        // Write them directly from code (contents from espeak-ng 1.52).
        let langDir = dest.appendingPathComponent("lang/gmw", isDirectory: true)
        try fm.createDirectory(at: langDir, withIntermediateDirectories: true)

        // en-US voice definition
        let enUS = """
        name English (America)
        language en-us 2
        language en 3

        phonemes en-us
        dictrules 3 6

        stressLength 140 120 190 170 0 0 255 300
        stressAmp  17 16  19 19  19 19  21 19

        replace 03 I  i
        replace 03 I2 i
        """
        try enUS.write(
            to: langDir.appendingPathComponent("en-US"),
            atomically: true, encoding: .utf8
        )

        // en (GB) — needed as fallback
        let enGB = """
        name English (Great Britain)
        language en-gb  2
        language en 2

        tunes s1 c1 q1 e1
        """
        try enGB.write(
            to: langDir.appendingPathComponent("en"),
            atomically: true, encoding: .utf8
        )

        // ── Required subdirectories (espeak scans these even if empty) ──
        let voicesDir = dest.appendingPathComponent("voices/!v", isDirectory: true)
        try fm.createDirectory(at: voicesDir, withIntermediateDirectories: true)

        return dest.path
    }
}

// MARK: - ONNX Inference

extension KittenTTSEngine {

    nonisolated private static func runInference(
        session: ORTSession,
        tokens: [Int64],
        style: [Float],
        speed: Float
    ) throws -> [Float] {

        let idShape: [NSNumber] = [1, NSNumber(value: tokens.count)]
        let idData  = tokens.withUnsafeBufferPointer { Data(buffer: $0) }
        let idTensor = try ORTValue(
            tensorData: NSMutableData(data: idData), elementType: .int64, shape: idShape
        )

        let stData   = style.withUnsafeBufferPointer { Data(buffer: $0) }
        let stTensor = try ORTValue(
            tensorData: NSMutableData(data: stData), elementType: .float, shape: [1, 256]
        )

        var sp = speed
        let spData   = Data(bytes: &sp, count: MemoryLayout<Float>.size)
        let spTensor = try ORTValue(
            tensorData: NSMutableData(data: spData), elementType: .float, shape: [1]
        )

        let outputs = try session.run(
            withInputs: ["input_ids": idTensor, "style": stTensor, "speed": spTensor],
            outputNames: ["waveform"],
            runOptions: nil
        )

        guard let waveform = outputs["waveform"] else {
            throw TTSError.inferenceError("No waveform in output")
        }

        let raw = try waveform.tensorData() as Data
        let totalSamples = raw.count / MemoryLayout<Float>.size
        let trimCount    = min(5000, totalSamples)
        let usableCount  = max(0, totalSamples - trimCount)
        guard usableCount > 0 else { return [] }

        var samples = [Float](repeating: 0, count: usableCount)
        raw.withUnsafeBytes { buf in
            let src = buf.bindMemory(to: Float.self)
            for i in 0..<usableCount { samples[i] = src[i] }
        }
        return samples
    }
}

// MARK: - Text Processing

extension KittenTTSEngine {

    nonisolated static func chunkText(_ text: String, maxLen: Int = 400) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let sentences = trimmed
            .split(omittingEmptySubsequences: true) { ".!?".contains($0) }
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !sentences.isEmpty else { return [trimmed] }

        var chunks: [String] = []
        for sentence in sentences {
            if sentence.count <= maxLen {
                chunks.append(sentence)
            } else {
                var buf = ""
                for word in sentence.split(separator: " ") {
                    if buf.count + word.count + 1 <= maxLen {
                        buf += (buf.isEmpty ? "" : " ") + word
                    } else {
                        if !buf.isEmpty { chunks.append(buf) }
                        buf = String(word)
                    }
                }
                if !buf.isEmpty { chunks.append(buf) }
            }
        }
        return chunks
    }

    nonisolated static func ensurePunctuation(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard let last = t.last else { return t }
        return ".!?,;:".contains(last) ? t : t + ","
    }

    /// Phonemize text while preserving punctuation.
    /// Matches Python `phonemizer` with `preserve_punctuation=True`:
    /// split on punctuation, phonemize each segment, re-insert punctuation.
    nonisolated static func phonemizePreservingPunctuation(_ text: String) -> String {
        let punctChars: Set<Character> = Set(";:,.!?—…")
        var segments: [(text: String, isPunct: Bool)] = []
        var current = ""

        // Split text into alternating (words, punctuation) segments
        for ch in text {
            if punctChars.contains(ch) {
                if !current.isEmpty {
                    segments.append((current, false))
                    current = ""
                }
                segments.append((String(ch), true))
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            segments.append((current, false))
        }

        // Phonemize non-punctuation segments with espeak, keep punctuation as-is
        var result = ""
        for seg in segments {
            if seg.isPunct {
                result += seg.text
            } else {
                let trimmed = seg.text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else {
                    result += seg.text  // preserve whitespace
                    continue
                }
                if let cResult = espeak_bridge_phonemize(trimmed) {
                    let phonemes = String(cString: cResult)
                    free(cResult)
                    result += phonemes
                }
            }
        }

        return result
    }

    nonisolated static func basicEnglishTokenize(_ text: String) -> String {
        var tokens: [String] = []
        var word = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "_" {
                word.append(ch)
            } else if !ch.isWhitespace {
                if !word.isEmpty { tokens.append(word); word = "" }
                tokens.append(String(ch))
            } else {
                if !word.isEmpty { tokens.append(word); word = "" }
            }
        }
        if !word.isEmpty { tokens.append(word) }
        return tokens.joined(separator: " ")
    }

    nonisolated static func phonemesToTokens(_ text: String) -> [Int64] {
        var tokens: [Int64] = []
        for scalar in text.unicodeScalars {
            if let id = vocabulary[scalar.value] {
                tokens.append(id)
            }
        }
        return tokens
    }

    nonisolated static let vocabulary: [UInt32: Int64] = {
        let pad        = "$"
        let punct      = ";:,.!?\u{00A1}\u{00BF}\u{2014}\u{2026}\"\u{00AB}\u{00BB}\u{201C}\u{201D} "
        let letters    = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
        let ipa        = "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘\u{2018}\u{0329}\u{2019}ᵻ"

        let all = pad + punct + letters + ipa
        var v: [UInt32: Int64] = [:]
        var i: Int64 = 0
        for s in all.unicodeScalars {
            v[s.value] = i
            i += 1
        }
        return v
    }()
}
