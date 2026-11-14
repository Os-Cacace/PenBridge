// Glide typing: turns a finger or pen path across the keys into the most likely word.
//
// Each word's "template" is the polyline through its letters' key centres. A path is
// compared with every template that starts near the path's first point and ends near
// its last, by two measures: the shape distance between both lines resampled to the
// same number of points, and how closely the path passes each letter in order. The
// word's frequency (crawled offline from the macOS spell checker, see
// keyboard/lexgen.swift) breaks ties between similar shapes.
//
// Coordinates are in key widths, so the same numbers work at any keyboard size.
import Foundation
import CoreGraphics

struct LexWord {
    let word: String
    let keys: [Character]      // letters as keys on the layout, repeats collapsed
    var logFreq: Double        // log10 of the estimated frequency, about -8...0
}

/// Maps a word's characters onto layout keys: case and accents are folded, Arabic hamza
/// forms of alef go to alef, and harakat and apostrophes are skipped.
func glideKeys(_ word: String, arabic: Bool) -> [Character] {
    var out: [Character] = []
    for ch in word {
        var c = ch
        if arabic {
            if "أإآٱ".contains(c) { c = "ا" }
            if let s = c.unicodeScalars.first, (0x064B...0x0652).contains(s.value) || s.value == 0x0640 { continue }
        } else {
            let folded = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            guard let f = folded.first, f.isLetter, f.isASCII else { continue }
            c = f
        }
        if out.last != c { out.append(c) }
    }
    return out
}

final class Lexicon {
    let arabic: Bool
    private(set) var byFirst: [Character: [Int]] = [:]
    private(set) var words: [LexWord] = []
    private var indexOf: [String: Int] = [:]
    private var learned: [String: Int] = [:]
    private let learnedURL: URL

    init(language: String) {
        arabic = language == "ar"
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Touchintosh", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        learnedURL = support.appendingPathComponent("learned-\(language).txt")

        // Built on this Mac by lexgen (see Lexicon.generate), else a copy in the app bundle.
        let candidates = [Lexicon.generatedURL(language),
                          Bundle.main.url(forResource: language, withExtension: "txt", subdirectory: "lexicon")].compactMap { $0 }
        let list = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        if let list, let text = try? String(contentsOf: list, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let f = Double(parts[1]) else { continue }
                add(String(parts[0]), logFreq: f)
            }
        }
        if let text = try? String(contentsOf: learnedURL, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "\t")
                guard parts.count == 2, let n = Int(parts[1]) else { continue }
                learned[String(parts[0])] = n
                boost(String(parts[0]), count: n)
            }
        }
    }

    private func add(_ word: String, logFreq: Double) {
        if let i = indexOf[word] { words[i].logFreq = max(words[i].logFreq, logFreq); return }
        let keys = glideKeys(word, arabic: arabic)
        guard let first = keys.first else { return }
        // A lower-case form wins over a capitalised duplicate ("will" over "Will").
        if !arabic, word != word.lowercased(), let i = indexOf[word.lowercased()] {
            words[i].logFreq = max(words[i].logFreq, logFreq - 1); return
        }
        indexOf[word] = words.count
        byFirst[first, default: []].append(words.count)
        words.append(LexWord(word: word, keys: keys, logFreq: logFreq))
    }

    private func boost(_ word: String, count: Int) {
        let f = -2.5 + 0.5 * log10(Double(count) + 1)
        add(word, logFreq: f)
    }

    func contains(_ word: String) -> Bool { indexOf[word] != nil || indexOf[word.lowercased()] != nil }

    /// Where the word list built on this Mac lives.
    static func generatedURL(_ language: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Touchintosh/lexicon-\(language).txt")
    }

    /// The word lists come from the macOS spell checker on the user's own Mac, so none of
    /// Apple's data ships with Touchintosh. Runs the bundled lexgen helper (a minute or two)
    /// and calls done on the main thread when the list is in place.
    static func generate(_ language: String, done: @escaping (Bool) -> Void) {
        guard let tool = Bundle.main.url(forAuxiliaryExecutable: "lexgen") else { done(false); return }
        let out = generatedURL(language)
        let tmp = out.appendingPathExtension("tmp")
        let p = Process()
        p.executableURL = tool
        p.arguments = [language, tmp.path]
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            var ok = proc.terminationStatus == 0 && FileManager.default.fileExists(atPath: tmp.path)
            if ok {
                try? FileManager.default.removeItem(at: out)
                ok = (try? FileManager.default.moveItem(at: tmp, to: out)) != nil
            }
            DispatchQueue.main.async { done(ok) }
        }
        do { try p.run() } catch { done(false) }
    }

    /// Remembers a word the user typed or picked, so it ranks higher next time.
    func learn(_ word: String) {
        let w = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard w.count >= 2, w.count <= 30, w.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
        let n = (learned[w] ?? 0) + 1
        learned[w] = n
        boost(w, count: n)
        let text = learned.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        DispatchQueue.global(qos: .utility).async { [learnedURL] in try? text.write(to: learnedURL, atomically: true, encoding: .utf8) }
    }
}

struct GlideCandidate { let word: String; let score: Double }

enum GlideDecoder {
    static let samples = 32
    // Weights, tuned with keyboard/test (GLIDE_W="shape align ends freq" overrides them there).
    static var weights: (shape: Double, align: Double, ends: Double, freq: Double) = {
        let v = (ProcessInfo.processInfo.environment["GLIDE_W"] ?? "").split(separator: " ").compactMap { Double($0) }
        return v.count == 4 ? (v[0], v[1], v[2], v[3]) : (12, 4, 4, 2.5)
    }()

    /// `keyCenters` maps each letter key to its centre, `path` is the stroke; both in key widths.
    static func decode(path raw: [CGPoint], keyCenters: [Character: CGPoint], lexicon: Lexicon,
                       limit: Int = 4) -> [GlideCandidate] {
        guard raw.count >= 2 else { return [] }
        let path = resample(raw, samples)
        let length = polylineLength(raw)
        guard let start = raw.first, let end = raw.last, length > 0.35 else { return [] }

        func near(_ p: CGPoint, _ r: Double) -> [Character: Double] {
            var out: [Character: Double] = [:]
            for (k, c) in keyCenters {
                let d = hypot(c.x - p.x, c.y - p.y)
                if d < r { out[k] = d }
            }
            return out
        }
        let starts = near(start, 1.25), ends = near(end, 1.25)
        var best: [GlideCandidate] = []
        var templateBuffer: [CGPoint] = []
        let w8 = weights
        for (first, dFirst) in starts {
            for i in lexicon.byFirst[first] ?? [] {
                let w = lexicon.words[i]
                guard w.keys.count >= 2, let last = w.keys.last, let dLast = ends[last] else { continue }
                templateBuffer.removeAll(keepingCapacity: true)
                var ok = true
                for k in w.keys {
                    guard let c = keyCenters[k] else { ok = false; break }
                    templateBuffer.append(c)
                }
                guard ok else { continue }
                let tLength = polylineLength(templateBuffer)
                // A path far shorter or longer than the word's template can't be it.
                guard tLength > 0, length / tLength > 0.45, length / tLength < 2.6 else { continue }
                let template = resample(templateBuffer, samples)

                var shape = 0.0
                for j in 0..<samples { shape += hypot(path[j].x - template[j].x, path[j].y - template[j].y) }
                shape /= Double(samples)
                if shape > 1.4 { continue }

                let align = alignment(raw, templateBuffer)
                // The finger lands on the first letter and lifts on the last, so those count extra.
                let cost = w8.shape * shape + w8.align * align + w8.ends * (dFirst * dFirst + dLast * dLast)
                let score = -cost + w8.freq * w.logFreq
                if best.count < limit || score > best[best.count - 1].score {
                    best.append(GlideCandidate(word: w.word, score: score))
                    best.sort { $0.score > $1.score }
                    if best.count > limit { best.removeLast() }
                }
            }
        }
        return best
    }

    /// How closely the path passes each letter of the word, in order: the mean of each
    /// letter's distance to the nearest path point at or after the previous letter's.
    static func alignment(_ path: [CGPoint], _ letters: [CGPoint]) -> Double {
        var index = 0, total = 0.0
        for (n, c) in letters.enumerated() {
            if n == letters.count - 1 {
                let d = hypot(path[path.count - 1].x - c.x, path[path.count - 1].y - c.y)
                total += d * d
                break
            }
            var bestD = Double.infinity, bestI = index
            // Only look ahead a share of the path proportional to the letters left.
            let remaining = letters.count - n
            let window = max(4, (path.count - index) * 2 / max(remaining, 1) + 4)
            for i in index..<min(path.count, index + window) {
                let d = hypot(path[i].x - c.x, path[i].y - c.y)
                if d < bestD { bestD = d; bestI = i }
            }
            total += bestD * bestD
            index = bestI
        }
        return (total / Double(letters.count)).squareRoot()
    }

    static func polylineLength(_ p: [CGPoint]) -> Double {
        var l = 0.0
        for i in 1..<max(p.count, 1) { l += hypot(p[i].x - p[i - 1].x, p[i].y - p[i - 1].y) }
        return l
    }

    static func resample(_ p: [CGPoint], _ n: Int) -> [CGPoint] {
        guard p.count > 1 else { return Array(repeating: p.first ?? .zero, count: n) }
        let total = polylineLength(p)
        guard total > 0 else { return Array(repeating: p[0], count: n) }
        let step = total / Double(n - 1)
        var out = [p[0]]
        out.reserveCapacity(n)
        var acc = 0.0, prev = p[0], i = 1
        while i < p.count && out.count < n {
            let cur = p[i]
            let d = hypot(cur.x - prev.x, cur.y - prev.y)
            if acc + d >= step && d > 0 {
                let t = (step - acc) / d
                let q = CGPoint(x: prev.x + t * (cur.x - prev.x), y: prev.y + t * (cur.y - prev.y))
                out.append(q); prev = q; acc = 0
            } else {
                acc += d; prev = cur; i += 1
            }
        }
        while out.count < n { out.append(p[p.count - 1]) }
        return out
    }
}
