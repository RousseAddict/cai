import Foundation
import AVFoundation

// Speaks an assistant reply out loud, one sentence-sized chunk at a time.
//
// Chunking matters for two reasons: synthesis latency scales with input length (a whole
// reply would take many seconds before the first sound), and a reply that is still
// streaming has no "whole" to send yet. So text is cut into chunks, each chunk is
// synthesized to an MP3 while the previous one plays, and `append` lets the caller keep
// feeding text as tokens arrive.
//
// Everything here is main-thread only: CurlFetcher delivers its completion on the main
// queue and AVAudioPlayer's delegate callbacks also land there, so no locking is needed.
final class TTSPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = TTSPlayer()

    // Don't synthesize a chunk shorter than this unless the text is finished — a 3-word
    // request costs a full round trip and sounds clipped.
    private static let minChunk = 80
    // Hard ceiling so a wall of text with no punctuation still gets spoken promptly.
    private static let maxChunk = 500
    // How many synthesized chunks to keep queued ahead of the one playing.
    private static let readyAhead = 2

    // Called whenever the speaking message changes, so the UI can retitle its buttons.
    var onStateChange: (() -> Void)?
    var onError: ((String) -> Void)?

    // Identifies the message being spoken ("<conversationID>:<row>"); nil = idle.
    private(set) var speakingKey: String?

    private var full: [Character] = []
    private var cursor = 0                 // how much of `full` has been cut into chunks
    private var pending: [String] = []     // cut, not yet synthesized
    private var ready: [String] = []       // synthesized file paths, not yet played
    private var isSynthesizing = false
    private var streamComplete = false
    private var player: AVAudioPlayer?

    // Bumped by stop(); in-flight synthesis callbacks compare against it and bail out.
    private var generation = 0

    private static let cacheDir: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        let dir = (docs as NSString).appendingPathComponent("tts")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
        return dir
    }()

    private override init() { super.init() }

    // MARK: - Public API

    func isSpeaking(key: String) -> Bool {
        return speakingKey == key
    }

    // Starts speaking `text`. If it belongs to a reply that is still streaming, pass
    // isComplete: false and keep calling append() as more text arrives.
    func speak(key: String, text: String, isComplete: Bool) {
        stop()
        speakingKey = key
        full = Array(text)
        streamComplete = isComplete
        activateSession()
        drain()
        pump()
        onStateChange?()
    }

    // Feeds the latest full text of the message being spoken. Ignored for other messages.
    func append(key: String, fullText: String) {
        guard speakingKey == key, !streamComplete else { return }
        full = Array(fullText)
        drain()
        pump()
    }

    // Marks the streaming reply as finished; flushes whatever tail is left.
    func finish(key: String) {
        guard speakingKey == key else { return }
        streamComplete = true
        drain()
        pump()
    }

    func stop() {
        generation += 1
        player?.stop()
        player = nil
        speakingKey = nil
        full = []
        cursor = 0
        pending = []
        ready = []
        isSynthesizing = false
        streamComplete = false
        onStateChange?()
    }

    // MARK: - Chunking

    // Cuts as much of the un-chunked tail of `full` into speakable chunks as it can.
    private func drain() {
        while cursor < full.count {
            let remaining = full.count - cursor
            var end = -1

            // Prefer a sentence boundary at least minChunk in.
            var i = cursor + TTSPlayer.minChunk
            while i < full.count && i < cursor + TTSPlayer.maxChunk {
                let c = full[i]
                if c == "." || c == "!" || c == "?" || c == "\n" {
                    end = i
                    break
                }
                i += 1
            }

            if end < 0 && remaining >= TTSPlayer.maxChunk {
                // No punctuation in range — break on the last space instead of mid-word.
                var j = cursor + TTSPlayer.maxChunk - 1
                while j > cursor + TTSPlayer.minChunk && full[j] != " " { j -= 1 }
                end = j
            }

            if end < 0 {
                // Not enough text yet. Once the stream is done, speak the tail as-is.
                if streamComplete && remaining > 0 { end = full.count - 1 } else { return }
            }

            let chunk = String(full[cursor...end]).trimmingCharacters(in: .whitespacesAndNewlines)
            cursor = end + 1
            if !chunk.isEmpty { pending.append(chunk) }
        }
    }

    // MARK: - Pipeline

    private func pump() {
        pumpSynthesis()
        pumpPlayback()
        checkDone()
    }

    private func pumpSynthesis() {
        guard !isSynthesizing, !pending.isEmpty, ready.count < TTSPlayer.readyAhead else { return }

        let model = Settings.ttsModel
        let voice = Settings.ttsVoice
        let chunk = pending.removeFirst()
        let path = cachePath(for: chunk, model: model, voice: voice)

        if FileManager.default.fileExists(atPath: path) {
            ready.append(path)
            pumpSynthesis()
            pumpPlayback()
            return
        }

        isSynthesizing = true
        let gen = generation
        TTSAPI.synthesize(text: chunk, model: model, voice: voice, apiKey: Settings.apiKey) { [weak self] data, error in
            guard let self = self, gen == self.generation else { return }
            self.isSynthesizing = false
            if let data = data, (data as NSData).write(toFile: path, atomically: true) {
                self.ready.append(path)
            } else {
                // One failed chunk shouldn't kill the rest of the reply — report and skip.
                self.onError?(error ?? "Speech synthesis failed.")
            }
            self.pump()
        }
    }

    private func pumpPlayback() {
        guard player == nil, !ready.isEmpty else { return }
        let path = ready.removeFirst()
        do {
            let p = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            p.delegate = self
            player = p
            p.prepareToPlay()
            if !p.play() {
                player = nil
                onError?("Could not play synthesized audio.")
            }
        } catch {
            player = nil
            onError?("Could not open synthesized audio.")
        }
    }

    // Speaking is over only when the stream ended AND the whole pipeline has drained.
    private func checkDone() {
        guard speakingKey != nil, streamComplete, player == nil,
              ready.isEmpty, pending.isEmpty, !isSynthesizing, cursor >= full.count else { return }
        stop()
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        guard p === player else { return }
        player = nil
        pump()
    }

    func audioPlayerDecodeErrorDidOccur(_ p: AVAudioPlayer, error: Error?) {
        guard p === player else { return }
        player = nil
        pump()
    }

    // MARK: - Cache

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }

    // Content-addressed so identical text is never synthesized (or billed) twice.
    private func cachePath(for text: String, model: String, voice: String) -> String {
        let key = "\(model)|\(voice)|\(text)"
        let name = String(format: "%08x-%d.mp3", TTSPlayer.hash(key), key.utf8.count)
        return (TTSPlayer.cacheDir as NSString).appendingPathComponent(name)
    }

    // djb2 — CommonCrypto isn't bridged here and a collision only costs a wrong cache hit,
    // which the length suffix already makes vanishingly unlikely.
    private static func hash(_ s: String) -> UInt32 {
        var h: UInt32 = 5381
        for b in s.utf8 { h = (h &* 33) &+ UInt32(b) }
        return h
    }
}
