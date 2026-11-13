import AppKit
import IslandCore
import SwiftUI

// Chess and the agents' usage limit: ears, ball glyphs and cards, ported from the sim (`ACT.chess`,
// `aglimit`, `agback` in sim/src/acts.js and agents.js; styles in acts.css).

// MARK: - Ears

struct SessionAlertEars: View {
    let instance: ActivityInstance
    let side: EarSide
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        HStack(spacing: 7) {
            switch (instance.id, side) {
            case (.chess, .left):
                let c = director.chessFor(instance)
                ChessToken(piece: c.now.piece, size: 22).entrance(side, 0)
                Text(c.now.san).font(IslandType.ear.monospacedDigit()).entrance(side, 1)
            case (.chess, .right):
                let c = director.chessFor(instance)
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text(clockText(c.mine.rounded(.up))).font(IslandType.ear.monospacedDigit())
                        .foregroundStyle(c.mine < 20 ? IslandColor.red : .white)
                }
                .entrance(side, 0)
            case (.agentLimit, .left), (.agentBack, .left):
                let l = director.limitFor(instance)
                AgentMark(provider: l.provider, size: 16).entrance(side, 0)
                Text(instance.id == .agentLimit ? "Limit" : l.provider.name).font(IslandType.ear).entrance(side, 1)
            case (.agentLimit, .right):
                Text(director.limitFor(instance).resets.map { "until \($0)" } ?? "Usage limit").font(IslandType.ear)
                    .foregroundStyle(IslandColor.red).entrance(side, 0)
            case (.agentBack, .right):
                Text("is back").font(IslandType.ear).foregroundStyle(IslandColor.green).entrance(side, 0)
            default:
                EmptyView()
            }
        }
    }
}

/// The ball's glyph for these activities.
struct SessionAlertGlyph: View {
    let instance: ActivityInstance
    let director: IslandDirector

    var body: some View {
        let _ = director.now
        switch instance.id {
        case .chess: ChessToken(piece: director.chessFor(instance).now.piece, size: 22)
        case .agentLimit, .agentBack:
            let p = director.limitFor(instance).provider
            AgentMark(provider: p, size: 15)
        default: EmptyView()
        }
    }
}

// MARK: - Cards

struct SessionAlertCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let _ = director.now
        switch instance.id {
        case .chess: ChessCard(instance: instance, director: director)
        case .agentLimit:
            let l = director.limitFor(instance)
            Row(lead: AlertMark(provider: l.provider, color: IslandColor.red), title: "\(l.provider.name) hit its usage limit",
                sub: l.resets.map { "Resets at \($0) · sessions pause until then" } ?? "Sessions pause until it resets")
        case .agentBack:
            let l = director.limitFor(instance)
            Row(lead: AlertMark(provider: l.provider, color: IslandColor.green), title: "\(l.provider.name) is back",
                sub: "The limit reset · paused sessions can carry on")
        default: EmptyView()
        }
    }
}

/// The sim's `.row-call`: a glyph, then a title over a secondary line.
private struct Row<Lead: View>: View {
    let lead: Lead
    let title: String
    let sub: String

    var body: some View {
        HStack(spacing: 12) {
            lead.rise(0)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(IslandType.title).lineLimit(1)
                Text(sub).font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }
}

/// The provider's mark on a 44 pt tinted disc (sim `.ag-alert`).
private struct AlertMark: View {
    let provider: AgentProvider
    let color: Color
    var body: some View {
        AgentMark(provider: provider, size: 24)
            .frame(width: 44, height: 44).background(Circle().fill(color.opacity(0.22)))
    }
}

// MARK: - Chess

/// The moved piece on a small disc: a light disc for Black's pieces, a warm grey one for White's.
struct ChessToken: View {
    let piece: Character
    let size: Double

    var body: some View {
        let white = piece.isUppercase
        Text(ChessSample.glyph(piece))
            .font(.custom("Apple Symbols", size: (size * 0.72).rounded()))
            .foregroundStyle(white ? .white : Color(hex: "#1C1C1E"))
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: white ? "#77726A" : "#ECE7DC")))
            .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
    }
}

private struct ChessCard: View {
    let instance: ActivityInstance
    let director: IslandDirector
    @Environment(\.presenting) private var presenting

    var body: some View {
        let c = director.chessFor(instance), n = c.now
        HStack(spacing: 14) {
            ChessBoard(board: ChessSample.board(c.step), from: n.from, to: n.to).rise(0)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Your move").font(IslandType.title).lineLimit(1)
                        (Text("\(presenting ? "Opponent" : ChessSample.opponent) played ") + Text(n.san).foregroundStyle(.white).fontWeight(.semibold))
                            .font(IslandType.secondary).foregroundStyle(IslandColor.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    RoundButton(symbol: "arrow.up.right", style: .gray, size: 36, label: "Open game") { director.chessOpen(instance) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    clock(c.mine.rounded(.up), mine: true, low: c.mine < 20)
                    clock(n.theirClock, mine: false, low: false)
                }
            }
            .frame(height: 100)
            .rise(1)
        }
        .frame(maxHeight: .infinity)
    }

    private func clock(_ seconds: Double, mine: Bool, low: Bool) -> some View {
        HStack(spacing: 7) {
            Circle().fill(mine ? Color.white : Color(hex: "#1C1C1E"))
                .overlay(mine ? nil : Circle().strokeBorder(.white.opacity(0.55), lineWidth: 1))
                .frame(width: 8, height: 8)
            Text(clockText(seconds)).font(.system(size: 17, weight: .semibold).monospacedDigit())
                .foregroundStyle(low ? IslandColor.red : mine ? .white : .white.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(.white.opacity(mine ? 0.16 : 0.08)))
    }
}

/// A muted board from White's side, the last move's two squares in soft yellow.
private struct ChessBoard: View {
    let board: [Character?]
    let from: Int
    let to: Int

    var body: some View {
        let cell = 100.0 / 8
        VStack(spacing: 0) {
            ForEach(0..<8, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { f in
                        let i = r * 8 + f
                        ZStack {
                            Rectangle().fill(Color(hex: (r + f) % 2 == 1 ? "#8B8579" : "#CDC8BD"))
                            if i == from || i == to { Rectangle().fill(Color(red: 1, green: 214 / 255, blue: 10 / 255).opacity(0.55)) }
                            if let p = board[i] {
                                Text(ChessSample.glyph(p)).font(.custom("Apple Symbols", size: 11))
                                    .foregroundStyle(p.isUppercase ? .white : Color(hex: "#151515"))
                                    .shadow(color: p.isUppercase ? .black.opacity(0.8) : .clear, radius: 0.4)
                                    .shadow(color: p.isUppercase ? .black.opacity(0.6) : .clear, radius: 0.4)
                            }
                        }
                        .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.2), lineWidth: 0.5))
        .accessibilityLabel("Board after the opponent's move")
    }
}
