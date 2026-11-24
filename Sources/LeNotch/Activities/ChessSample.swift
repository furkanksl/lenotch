/// Chess (11-06, docs/superpowers/specs/2026-11-06-chess-design.md): the sample game from the sim (`CHESS`). You're
/// White in a Najdorf; each step is your move, the opponent's reply as it arrives, its SAN and both clocks (seconds).
/// The live route (the chess.com page through the browser extension) isn't built: only the sample shows. Fair play:
/// the notch shows the position and the move played, never anything computed about it.
enum ChessSample {
    static let opponent = "Owen Clark"
    static let line: [(mine: String, theirs: String, san: String, myClock: Double, theirClock: Double)] = [
        ("e2e4", "c7c5", "c5", 171, 176), ("g1f3", "d7d6", "d6", 160, 167), ("d2d4", "c5d4", "cxd4", 142, 161),
        ("f3d4", "g8f6", "Nf6", 118, 150), ("b1c3", "a7a6", "a6", 24, 132),
    ]

    /// a8 = 0 … h1 = 63: White at the bottom.
    static func square(_ s: Substring) -> Int {
        let file = Int(s.unicodeScalars.first!.value) - 97, rank = Int(String(s.last!))!
        return (8 - rank) * 8 + file
    }

    /// The position after the opponent's reply in `step`: FEN letters (upper case White), nil for empty squares.
    static func board(_ step: Int) -> [Character?] {
        var b: [Character?] = []
        for ch in "rnbqkbnrpppppppp" { b.append(ch) }
        b += Array(repeating: nil, count: 32)
        for ch in "PPPPPPPPRNBQKBNR" { b.append(ch) }
        for pair in line.prefix(step + 1) {
            for m in [pair.mine, pair.theirs] {
                let from = square(m.prefix(2)), to = square(m.dropFirst(2))
                b[to] = b[from]; b[from] = nil
            }
        }
        return b
    }

    struct Now: Equatable {
        var from: Int
        var to: Int
        var san: String
        var myClock: Double
        var theirClock: Double
        var piece: Character
    }

    static func now(_ step: Int) -> Now {
        let s = line[step % line.count], to = square(s.theirs.dropFirst(2))
        return Now(from: square(s.theirs.prefix(2)), to: to, san: s.san, myClock: s.myClock, theirClock: s.theirClock,
                   piece: board(step % line.count)[to] ?? "p")
    }

    /// The figurine in text presentation (never the emoji).
    static func glyph(_ p: Character) -> String {
        let g: [Character: String] = ["k": "♚", "q": "♛", "r": "♜", "b": "♝", "n": "♞", "p": "♟"]
        return (g[Character(p.lowercased())] ?? "♟") + "\u{FE0E}"
    }
}
