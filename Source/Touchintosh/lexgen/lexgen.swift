// Builds a ranked word list for glide typing from macOS's own spell checker, offline.
// NSSpellChecker completions come back ordered by how common each word is, 20 at a
// time, so crawling prefixes and chaining the ranks gives an estimated frequency.
// Usage: lexgen <en|ar> <out.txt>   (writes "word<TAB>log10 frequency", most common first)
import AppKit

let lang = CommandLine.arguments[1], out = CommandLine.arguments[2]
let sc = NSSpellChecker.shared
let alphabet: [String] = lang == "ar"
    ? "ا ب ت ث ج ح خ د ذ ر ز س ش ص ض ط ظ ع غ ف ق ك ل م ن ه و ي ء أ إ آ ؤ ئ ى ة".split(separator: " ").map(String.init)
    : "abcdefghijklmnopqrstuvwxyz".map(String.init)
var dictPrefixes = Set<String>()
if lang == "en", let words = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
    for w in words.split(separator: "\n") {
        let l = w.lowercased()
        var p = ""
        for c in l.prefix(9) { p.append(c); dictPrefixes.insert(p) }
    }
}
func query(_ p: String) -> [String] {
    sc.completions(forPartialWordRange: NSRange(location: 0, length: (p as NSString).length), in: p,
                   language: lang, inSpellDocumentWithTag: 0) ?? []
}
let decay = 0.9
var est: [String: Double] = [:]
var queue: [(prefix: String, top: Double, floor: Double)] = alphabet.map { ($0, 1.0, 0) }
var queries = 0, head = 0
let maxQueries = 90_000, maxDepth = 8
while head < queue.count && queries < maxQueries {
    let (p, guessTop, floor) = queue[head]; head += 1
    let r = query(p); queries += 1
    if r.isEmpty { continue }
    // Anchor this list to words already ranked in a shorter prefix's list.
    var top = guessTop
    if let (k, e) = r.enumerated().lazy.compactMap({ i, w in est[w].map { (i, $0) } }).first {
        top = e * pow(Double(k + 1), decay)
    }
    if floor > 0 { top = min(top, floor * 0.95 * pow(Double(r.firstIndex { est[$0] == nil } ?? 0) + 1, decay)) }
    for (k, w) in r.enumerated() where !w.contains(" ") {
        let e = top / pow(Double(k + 1), decay)
        if est[w] == nil || est[w]! < e { if est[w] == nil { est[w] = e } }
    }
    let last = top / pow(Double(r.count), decay)
    guard r.count >= 20, (p as NSString).length < maxDepth else { continue }
    let depth = (p as NSString).length
    var children = Set<String>()
    for w in r { let s = w.lowercased(); if s.count > p.count { children.insert(String(s.prefix(p.count + 1))) } }
    for c in alphabet {
        let child = p + c
        if lang == "en" ? dictPrefixes.contains(child) : depth < 3 { children.insert(child) }
    }
    for child in children.sorted() where child.lowercased().hasPrefix(p.lowercased()) && child != p {
        queue.append((child, last, last))
    }
    if queries % 5000 == 0 { FileHandle.standardError.write("\(lang) \(queries) queries, \(est.count) words, queue \(queue.count - head)\n".data(using: .utf8)!) }
}
// Every first letter's list started at the same weight; scale each letter by how many
// words start with it, so "xenophobic" (top of x) doesn't rank with "the" (top of t).
func firstKey(_ w: String) -> String {
    var f = String(w.prefix(1)).lowercased()
    if "أإآ".contains(f) { f = "ا" }
    return f
}
var perLetter: [String: Int] = [:]
for w in est.keys { perLetter[firstKey(w), default: 0] += 1 }
let most = Double(perLetter.values.max() ?? 1)
for (w, e) in est { est[w] = e * pow(Double(perLetter[firstKey(w)] ?? 1) / most, 0.8) }
let ranked = est.sorted { $0.value > $1.value }.prefix(80_000)
let text = ranked.map { "\($0.key)\t\(String(format: "%.3f", log10($0.value)))" }.joined(separator: "\n")
try! text.write(toFile: out, atomically: true, encoding: .utf8)
print("\(lang): \(queries) queries, \(est.count) words found, wrote \(ranked.count)")
