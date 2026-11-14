// On-screen keyboard layouts. Widths are in key units; every row of a page adds up
// to the same width.
//
// Standard: iPad-style English and Arabic letter pages (optionally with a number
// row), plus numbers and symbols pages.
// Advanced: a full Mac layout (Esc, Tab, Caps Lock, Control, Option, Command,
// arrows) where every key also has its US key code, so shortcuts like ⌘C work
// whatever language the keyboard shows.
import Foundation
import CoreGraphics

enum Modifier: Int { case control, option, command }

enum KeyKind: Equatable {
    case char(String)       // types its text
    case shift, caps, delete, ret, space, globe, hide, tab, esc
    case modifier(Modifier)
    case arrow(CGKeyCode)
    case page(KeyPage)      // switches page
    case spacer             // empty room; touches go to the nearest key
}

enum KeyPage: Equatable { case letters, numbers, symbols }
enum KeyLanguage: String { case en, ar }

struct KeySpec {
    var kind: KeyKind
    var width: Double = 1
    var label: String? = nil          // shown instead of the text
    var alternates: [String] = []     // long-press choices
    var shifted: String? = nil        // typed with shift (non-letter keys)
    var code: CGKeyCode? = nil        // US key code, for shortcuts

    var text: String? { if case .char(let s) = kind { return s }; return nil }
    var isLetterKey: Bool { if case .char = kind { return true }; return false }
}

struct KeyboardLayout {
    let rows: [[KeySpec]]
    var units: Double { rows.map { $0.reduce(0) { $0 + $1.width } }.max() ?? 1 }
}

// MARK: - US key codes and shift symbols

let usKeyCodes: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
    "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
]
private let usShifted: [String: String] = [
    "`": "~", "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
    "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
]
// Arabic (PC) shift layer, by the US key in the same place.
private let arabicShifted: [String: String] = [
    "q": "َ", "w": "ً", "e": "ُ", "r": "ٌ", "t": "لإ", "y": "إ", "u": "‘", "i": "÷", "o": "×", "p": "؛", "[": "<", "]": ">",
    "a": "ِ", "s": "ٍ", "d": "]", "f": "[", "g": "لأ", "h": "أ", "j": "ـ", "k": "،", "l": "/", ";": ":", "'": "\"",
    "z": "~", "x": "ْ", "c": "}", "v": "{", "b": "لآ", "n": "آ", "m": "’", ",": ",", ".": ".", "/": "؟", "`": "ّ",
]
// Arabic letters on the same keys as the US letters (Arabic PC layout).
private let arabicByUS: [String: String] = [
    "q": "ض", "w": "ص", "e": "ث", "r": "ق", "t": "ف", "y": "غ", "u": "ع", "i": "ه", "o": "خ", "p": "ح", "[": "ج", "]": "د",
    "a": "ش", "s": "س", "d": "ي", "f": "ب", "g": "ل", "h": "ا", "j": "ت", "k": "ن", "l": "م", ";": "ك", "'": "ط",
    "z": "ئ", "x": "ء", "c": "ؤ", "v": "ر", "b": "لا", "n": "ى", "m": "ة", ",": "و", ".": "ز", "/": "ظ", "`": "ذ",
]

private let englishAlternates: [String: [String]] = [
    "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"], "c": ["ç", "ć", "č"],
    "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"], "i": ["ì", "í", "î", "ï", "ī"],
    "n": ["ñ", "ń"], "o": ["ò", "ó", "ô", "ö", "õ", "ø", "ō", "œ"],
    "s": ["ß", "ś", "š"], "u": ["ù", "ú", "û", "ü", "ū"], "y": ["ÿ"], "z": ["ž", "ź", "ż"],
    ".": ["…"], ",": ["'", "\""], "-": ["–", "—", "•"], "/": ["\\"], "$": ["€", "£", "¥", "₩", "¢"],
    "&": ["§"], "\"": ["“", "”", "„", "«", "»"], "'": ["‘", "’", "`"], "?": ["¿"], "!": ["¡"],
    "0": ["°"], "%": ["‰"],
]
private let arabicAlternates: [String: [String]] = [
    "ا": ["أ", "إ", "آ", "ٱ"], "ي": ["ى", "ئ"], "و": ["ؤ"], "ه": ["ة"], "ء": ["ئ", "ؤ", "أ", "إ"],
    "ل": ["لا", "لأ", "لإ", "لآ"], "ت": ["ة"], "ك": ["گ"], "ف": ["ڤ"], "ج": ["چ"], "ب": ["پ"],
    "1": ["١"], "2": ["٢"], "3": ["٣"], "4": ["٤"], "5": ["٥"], "6": ["٦"], "7": ["٧"], "8": ["٨"], "9": ["٩"], "0": ["٠"],
    ".": ["…"], "؟": ["?"], "،": [","], "؛": [";"],
]

private func chars(_ s: String, _ alts: [String: [String]] = [:]) -> [KeySpec] {
    s.split(separator: " ").map { KeySpec(kind: .char(String($0)), alternates: alts[String($0)] ?? []) }
}

/// A row of keys on the US positions `us`, showing English or the Arabic letter there.
private func positional(_ us: String, _ lang: KeyLanguage) -> [KeySpec] {
    us.split(separator: " ").map { u in
        let key = String(u)
        let ar = lang == .ar ? arabicByUS[key] : nil
        let text = ar ?? key
        let alts = lang == .ar ? (arabicAlternates[text] ?? []) : (englishAlternates[text] ?? [])
        let shifted = lang == .ar ? (arabicShifted[key] ?? usShifted[key]) : usShifted[key]
        return KeySpec(kind: .char(text), alternates: alts, shifted: shifted, code: usKeyCodes[key])
    }
}

/// Digits 1–0 with their shift symbols; long-press also gives the Arabic-Indic digit.
private func numberRow(_ lang: KeyLanguage, width: Double) -> [KeySpec] {
    "1 2 3 4 5 6 7 8 9 0".split(separator: " ").map { d in
        let k = String(d), s = usShifted[k]!
        let alts = (lang == .ar ? (arabicAlternates[k] ?? []) : []) + [s]
        return KeySpec(kind: .char(k), width: width, alternates: alts, shifted: s, code: usKeyCodes[k])
    }
}

/// total: the page's width, when it differs from the usual 11.5 (English) or 12.5 (Arabic).
private func bottomRow(_ lang: KeyLanguage, toPage: KeyPage, toLabel: String, total: Double? = nil) -> [KeySpec] {
    let ar = lang == .ar
    let space = total.map { $0 - 5.5 } ?? (ar ? 7 : 6)    // 5.5: the four keys around it
    return [KeySpec(kind: .page(toPage), width: 1.5, label: toLabel),
            KeySpec(kind: .globe, width: ar ? 1.25 : 1),
            KeySpec(kind: .space, width: space, label: ar ? "مسافة" : "space"),
            KeySpec(kind: .page(toPage), width: ar ? 1.25 : 1.5, label: toLabel),
            KeySpec(kind: .hide, width: 1.5)]
}

func keyboardLayout(_ lang: KeyLanguage, _ page: KeyPage, numberRow withNumbers: Bool, advanced: Bool) -> KeyboardLayout {
    if advanced { return advancedLayout(lang) }
    let ar = lang == .ar
    var rows: [[KeySpec]]
    switch (lang, page) {
    case (.en, .letters):
        rows = [
            chars("q w e r t y u i o p", englishAlternates) + [KeySpec(kind: .delete, width: 1.5)],
            [KeySpec(kind: .spacer, width: 0.5)] + chars("a s d f g h j k l", englishAlternates) + [KeySpec(kind: .ret, width: 2)],
            [KeySpec(kind: .shift, width: 1)] + chars("z x c v b n m , .", englishAlternates) + [KeySpec(kind: .shift, width: 1.5)],
            bottomRow(.en, toPage: .numbers, toLabel: ".?123"),
        ]
    case (.ar, .letters):
        // Mac Arabic positions: د ends the top row, لا sits on B, ذ is left of 1 (or starts
        // the bottom row without a number row). Shift types the harakat on the same keys.
        let punct = [KeySpec(kind: .char("،"), alternates: [","]), KeySpec(kind: .char("."), alternates: ["…", "؟", "!"])]
        let bottom = positional("z x c v b n m , . /", .ar) + punct
        rows = withNumbers ? [
            positional("q w e r t y u i o p [ ]", .ar) + [KeySpec(kind: .delete, width: 1.5)],
            positional("a s d f g h j k l ; '", .ar) + [KeySpec(kind: .ret, width: 2.5)],
            [KeySpec(kind: .shift, width: 1.5)] + bottom,
            bottomRow(.ar, toPage: .numbers, toLabel: "١٢٣", total: 13.5),
        ] : [
            positional("q w e r t y u i o p [ ]", .ar) + [KeySpec(kind: .delete, width: 2)],
            positional("a s d f g h j k l ; '", .ar) + [KeySpec(kind: .ret, width: 3)],
            [KeySpec(kind: .shift, width: 1)] + positional("`", .ar) + bottom,
            bottomRow(.ar, toPage: .numbers, toLabel: "١٢٣", total: 14),
        ]
    case (_, .numbers):
        let alts = ar ? arabicAlternates.merging(englishAlternates) { a, _ in a } : englishAlternates
        rows = [
            chars("1 2 3 4 5 6 7 8 9 0", alts) + [KeySpec(kind: .delete, width: 1.5)],
            [KeySpec(kind: .spacer, width: 0.5)] + chars(ar ? "- / : ؛ ( ) $ & @" : "- / : ; ( ) $ & @", alts) + [KeySpec(kind: .ret, width: 2)],
            [KeySpec(kind: .page(.symbols), width: 1, label: "#+=")]
                + chars(ar ? ". ، ؟ ! ' \" % * _" : ". , ? ! ' \" % * _", alts)
                + [KeySpec(kind: .page(.symbols), width: 1.5, label: "#+=")],
            bottomRow(lang, toPage: .letters, toLabel: ar ? "أبج" : "ABC"),
        ]
        return KeyboardLayout(rows: rows)   // already starts with digits
    case (_, .symbols):
        let third: [KeySpec] = ar
            ? "ً ٌ ٍ َ ُ ِ ّ ْ ـ".split(separator: " ").map { KeySpec(kind: .char(String($0)), label: $0 == "ـ" ? "ـ" : "◌" + $0) }
            : chars("• … ° © ® ™ § ¶ `")
        rows = [
            chars("[ ] { } # % ^ * + =") + [KeySpec(kind: .delete, width: 1.5)],
            [KeySpec(kind: .spacer, width: 0.5)] + chars("_ \\ | ~ < > € £ ¥") + [KeySpec(kind: .ret, width: 2)],
            [KeySpec(kind: .page(.numbers), width: 1, label: "123")] + third
                + [KeySpec(kind: .page(.numbers), width: 1.5, label: "123")],
            bottomRow(lang, toPage: .letters, toLabel: ar ? "أبج" : "ABC"),
        ]
    }
    if withNumbers {
        let units = KeyboardLayout(rows: rows).units
        if lang == .ar && page == .letters {
            var dhal = positional("`", .ar)[0]
            dhal.width = units / 11
            rows.insert([dhal] + numberRow(lang, width: units / 11), at: 0)
        } else {
            rows.insert(numberRow(lang, width: units / 10), at: 0)
        }
    }
    return KeyboardLayout(rows: rows)
}

// MARK: - Shortcut bar

enum ShortcutGroup: Int, CaseIterable {
    case edit, apps, move, system
    var title: String { ["Edit", "Apps", "Move", "System"][rawValue] }
}

struct Shortcut {
    let title: String
    let symbol: String
    let code: CGKeyCode
    let flags: CGEventFlags
}

private let cmd = CGEventFlags.maskCommand, shiftKey = CGEventFlags.maskShift
private let opt = CGEventFlags.maskAlternate, ctrl = CGEventFlags.maskControl
// Real arrow and page keys carry these; Mission Control ignores ⌃↑ without them.
private let arrowKey: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]

func shortcuts(_ group: ShortcutGroup) -> [Shortcut] {
    switch group {
    case .edit: return [
        Shortcut(title: "Undo", symbol: "arrow.uturn.backward", code: 6, flags: cmd),
        Shortcut(title: "Redo", symbol: "arrow.uturn.forward", code: 6, flags: [cmd, shiftKey]),
        Shortcut(title: "Cut", symbol: "scissors", code: 7, flags: cmd),
        Shortcut(title: "Copy", symbol: "doc.on.doc", code: 8, flags: cmd),
        Shortcut(title: "Paste", symbol: "doc.on.clipboard", code: 9, flags: cmd),
        Shortcut(title: "Select All", symbol: "selection.pin.in.out", code: 0, flags: cmd),
        Shortcut(title: "Find", symbol: "magnifyingglass", code: 3, flags: cmd),
        Shortcut(title: "Save", symbol: "square.and.arrow.down", code: 1, flags: cmd),
    ]
    case .apps: return [
        Shortcut(title: "Switch", symbol: "rectangle.stack", code: 48, flags: cmd),
        Shortcut(title: "New Tab", symbol: "plus.square.on.square", code: 17, flags: cmd),
        Shortcut(title: "New", symbol: "macwindow.badge.plus", code: 45, flags: cmd),
        Shortcut(title: "Close", symbol: "xmark.square", code: 13, flags: cmd),
        Shortcut(title: "Minimise", symbol: "minus.square", code: 46, flags: cmd),
        Shortcut(title: "Hide", symbol: "eye.slash", code: 4, flags: cmd),
        Shortcut(title: "Quit", symbol: "power", code: 12, flags: cmd),
        Shortcut(title: "Mission", symbol: "rectangle.3.group", code: 126, flags: ctrl.union(arrowKey)),
    ]
    case .move: return [
        Shortcut(title: "Line Start", symbol: "arrow.left.to.line", code: 123, flags: cmd.union(arrowKey)),
        Shortcut(title: "Word", symbol: "arrow.left", code: 123, flags: opt.union(arrowKey)),
        Shortcut(title: "Word", symbol: "arrow.right", code: 124, flags: opt.union(arrowKey)),
        Shortcut(title: "Line End", symbol: "arrow.right.to.line", code: 124, flags: cmd.union(arrowKey)),
        Shortcut(title: "Top", symbol: "arrow.up.to.line", code: 126, flags: cmd.union(arrowKey)),
        Shortcut(title: "Bottom", symbol: "arrow.down.to.line", code: 125, flags: cmd.union(arrowKey)),
        Shortcut(title: "Page", symbol: "chevron.up", code: 116, flags: .maskSecondaryFn),
        Shortcut(title: "Page", symbol: "chevron.down", code: 121, flags: .maskSecondaryFn),
    ]
    case .system: return [
        Shortcut(title: "Spotlight", symbol: "sparkle.magnifyingglass", code: 49, flags: cmd),
        Shortcut(title: "Screenshot", symbol: "camera.viewfinder", code: 23, flags: [cmd, shiftKey]),
        Shortcut(title: "Area Shot", symbol: "rectangle.dashed", code: 21, flags: [cmd, shiftKey]),
        Shortcut(title: "Emoji", symbol: "face.smiling", code: 49, flags: [cmd, ctrl]),
        Shortcut(title: "Force Quit", symbol: "xmark.octagon", code: 53, flags: [cmd, opt]),
        Shortcut(title: "Lock", symbol: "lock", code: 12, flags: [cmd, ctrl]),
    ]
    }
}

/// Full Mac layout, 15 units wide.
private func advancedLayout(_ lang: KeyLanguage) -> KeyboardLayout {
    let ar = lang == .ar
    var first = positional("` 1 2 3 4 5 6 7 8 9 0 - =", lang)
    if ar { first[0].alternates = ["`"] }
    for i in 1...10 { first[i].alternates = (ar ? (arabicAlternates[first[i].text ?? ""] ?? []) : []) }
    return KeyboardLayout(rows: [
        [KeySpec(kind: .esc, width: 1, label: "esc")] + first.dropFirst() + [KeySpec(kind: .delete, width: 2)],
        [KeySpec(kind: .tab, width: 1.5, label: "tab")] + positional("q w e r t y u i o p [ ]", lang)
            + positional("\\", lang).map { var k = $0; k.width = 1.5; return k },
        [KeySpec(kind: .caps, width: 1.75)] + positional("a s d f g h j k l ; '", lang) + [KeySpec(kind: .ret, width: 2.25)],
        [KeySpec(kind: .shift, width: 2.25)] + positional("z x c v b n m , . /", lang)
            + [first[0]] + [KeySpec(kind: .shift, width: 1.75)],
        [KeySpec(kind: .globe, width: 1),
         KeySpec(kind: .modifier(.control), width: 1.25, label: "control"),
         KeySpec(kind: .modifier(.option), width: 1.25, label: "option"),
         KeySpec(kind: .modifier(.command), width: 1.5, label: "command"),
         KeySpec(kind: .space, width: 5, label: ar ? "مسافة" : ""),
         KeySpec(kind: .arrow(123), width: 1), KeySpec(kind: .arrow(126), width: 1),
         KeySpec(kind: .arrow(125), width: 1), KeySpec(kind: .arrow(124), width: 1),
         KeySpec(kind: .hide, width: 1)],
    ])
}
