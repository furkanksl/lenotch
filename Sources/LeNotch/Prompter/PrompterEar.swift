import SwiftUI
import IslandCore

struct PrompterEar: View {
    let model: PrompterModel
    let side: EarSide

    var body: some View {
        if side == .left {
            Image(systemName: "text.alignleft").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(IslandColor.green)
            Text("Prompt").font(IslandType.caption)
        } else {
            HStack(spacing: 5) {
                Image(systemName: model.phase == .playing ? "play.fill" : "pause.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text(model.phase == .finished ? "Done" : "\(Int(model.progress * 100))%")
                    .font(IslandType.ear.monospacedDigit())
            }
            .foregroundStyle(IslandColor.green)
        }
    }
}
