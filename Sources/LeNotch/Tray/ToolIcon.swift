// Hugeicons Free Stroke Rounded, @hugeicons/core-free-icons v4.4.0.
// Copyright (c) 2026 Hugeicons. MIT License.
// Source: https://cdn.jsdelivr.net/npm/@hugeicons/core-free-icons@4.4.0/dist/esm/
// Existing icon cases name their original asset. Dictation uses a matching microphone outline.

import SwiftUI

enum ToolIcon: CaseIterable {
    case ask, dictation, timer, prompter, today, launcher, clipboard, shelf, shortcuts, usage, system, todo, inbox
}

struct ToolIconView: View {
    let icon: ToolIcon

    var body: some View {
        GeometryReader { geometry in
            ToolIconShape(icon: icon)
                .stroke(style: StrokeStyle(
                    lineWidth: min(geometry.size.width, geometry.size.height) * 1.5 / 24,
                    lineCap: .round,
                    lineJoin: .round
                ))
        }
        .accessibilityHidden(true)
    }
}

struct ToolIconShape: Shape {
    let icon: ToolIcon

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        guard side > 0 else { return Path() }

        var path = Path()
        switch icon {
        case .ask: // AiMagicIcon.js
            path.move(9.85267, 4.8654)
            path.line(8.7579, 8.69741)
            path.curve(8.47317, 9.69406, 7.69412, 10.4731, 6.69747, 10.7579)
            path.line(2.86538, 11.8528)
            path.curve(2.35315, 11.9991, 2, 12.4673, 2, 13)
            path.curve(2, 13.5327, 2.35315, 14.0009, 2.86538, 14.1472)
            path.line(6.69747, 15.2421)
            path.curve(7.69412, 15.5269, 8.47317, 16.3059, 8.7579, 17.3026)
            path.line(9.85267, 21.1346)
            path.curve(9.99902, 21.6468, 10.4672, 22, 10.9999, 22)
            path.curve(11.5327, 22, 12.0008, 21.6469, 12.1472, 21.1347)
            path.line(13.2422, 17.3025)
            path.curve(13.527, 16.3059, 14.306, 15.5269, 15.3026, 15.2421)
            path.line(19.1346, 14.1473)
            path.curve(19.6468, 14.0009, 20, 13.5327, 20, 13)
            path.curve(20, 12.4673, 19.6468, 11.9991, 19.1346, 11.8527)
            path.line(15.3026, 10.7579)
            path.curve(14.306, 10.4731, 13.527, 9.69411, 13.2422, 8.69753)
            path.line(12.1472, 4.86535)
            path.curve(12.0008, 4.35313, 11.5327, 4, 10.9999, 4)
            path.curve(10.4672, 4, 9.99902, 4.35316, 9.85267, 4.8654)
            path.closeSubpath()

            path.move(19.5, 2.9375)
            path.line(19.5, 4.5)
            path.move(19.5, 4.5)
            path.line(19.5, 6.0625)
            path.move(19.5, 4.5)
            path.line(18.25, 4.5)
            path.move(19.5, 4.5)
            path.line(20.75, 4.5)
            path.move(22, 4.5)
            path.line(20.9156, 4.13852)
            path.curve(20.4179, 3.97263, 20.0274, 3.58211, 19.8615, 3.08443)
            path.line(19.5, 2)
            path.line(19.1385, 3.08443)
            path.curve(18.9726, 3.58211, 18.5821, 3.97263, 18.0844, 4.13852)
            path.line(17, 4.5)
            path.line(18.0844, 4.86148)
            path.curve(18.5821, 5.02737, 18.9726, 5.41789, 19.1385, 5.91557)
            path.line(19.5, 7)
            path.line(19.8615, 5.91557)
            path.curve(20.0274, 5.41789, 20.4179, 5.02737, 20.9156, 4.86148)
            path.line(22, 4.5)
            path.closeSubpath()

        case .dictation: // Microphone outline on the 24-point grid.
            path.move(12, 15)
            path.curve(13.6569, 15, 15, 13.6569, 15, 12)
            path.line(15, 5)
            path.curve(15, 3.3431, 13.6569, 2, 12, 2)
            path.curve(10.3431, 2, 9, 3.3431, 9, 5)
            path.line(9, 12)
            path.curve(9, 13.6569, 10.3431, 15, 12, 15)
            path.closeSubpath()
            path.move(5, 10)
            path.line(5, 12)
            path.curve(5, 15.866, 8.134, 19, 12, 19)
            path.curve(15.866, 19, 19, 15.866, 19, 12)
            path.line(19, 10)
            path.move(12, 19)
            path.line(12, 22)
            path.move(8, 22)
            path.line(16, 22)

        case .timer: // Timer01Icon.js
            path.move(11.0809, 13.152)
            path.line(8, 7)
            path.line(13.4196, 11.2796)
            path.curve(14.1901, 11.888, 14.1941, 13.0472, 13.4277, 13.6607)
            path.curve(12.6614, 14.2743, 11.5189, 14.0266, 11.0809, 13.152)
            path.closeSubpath()

            path.move(5, 4.82)
            path.curve(3.14864, 6.63902, 2, 9.17385, 2, 11.9776)
            path.curve(2, 17.5129, 6.47715, 22.0001, 12, 22.0001)
            path.curve(17.5228, 22.0001, 22, 17.5129, 22, 11.9776)
            path.curve(22, 7.1242, 18.5581, 3.07656, 13.9872, 2.15288)
            path.curve(13.1512, 1.98394, 12.7332, 1.89947, 12.3666, 2.20022)
            path.curve(12, 2.50097, 12, 2.98714, 12, 3.95949)
            path.line(12, 4.96175)

        case .prompter: // TextAlignLeftIcon.js
            path.move(3, 3)
            path.line(21, 3)
            path.move(3, 9)
            path.line(11, 9)
            path.move(3, 15)
            path.line(21, 15)
            path.move(3, 21)
            path.line(11, 21)

        case .today: // Calendar03Icon.js
            path.move(16, 2)
            path.line(16, 6)
            path.move(8, 2)
            path.line(8, 6)

            path.move(13, 4)
            path.line(11, 4)
            path.curve(7.22876, 4, 5.34315, 4, 4.17157, 5.17157)
            path.curve(3, 6.34315, 3, 8.22876, 3, 12)
            path.line(3, 14)
            path.curve(3, 17.7712, 3, 19.6569, 4.17157, 20.8284)
            path.curve(5.34315, 22, 7.22876, 22, 11, 22)
            path.line(13, 22)
            path.curve(16.7712, 22, 18.6569, 22, 19.8284, 20.8284)
            path.curve(21, 19.6569, 21, 17.7712, 21, 14)
            path.line(21, 12)
            path.curve(21, 8.22876, 21, 6.34315, 19.8284, 5.17157)
            path.curve(18.6569, 4, 16.7712, 4, 13, 4)
            path.closeSubpath()

            path.move(3, 10)
            path.line(21, 10)

            path.move(12.1258, 14)
            path.line(12.0008, 14)
            path.move(12.1258, 18)
            path.line(12.0008, 18)
            path.move(7.625, 14)
            path.line(7.5, 14)
            path.move(7.625, 18)
            path.line(7.5, 18)
            path.move(16.625, 14)
            path.line(16.5, 14)
            path.move(12.2508, 14)
            path.curve(12.2508, 14.1381, 12.1389, 14.25, 12.0008, 14.25)
            path.curve(11.8628, 14.25, 11.7508, 14.1381, 11.7508, 14)
            path.curve(11.7508, 13.8619, 11.8628, 13.75, 12.0008, 13.75)
            path.curve(12.1389, 13.75, 12.2508, 13.8619, 12.2508, 14)
            path.closeSubpath()
            path.move(12.2508, 18)
            path.curve(12.2508, 18.1381, 12.1389, 18.25, 12.0008, 18.25)
            path.curve(11.8628, 18.25, 11.7508, 18.1381, 11.7508, 18)
            path.curve(11.7508, 17.8619, 11.8628, 17.75, 12.0008, 17.75)
            path.curve(12.1389, 17.75, 12.2508, 17.8619, 12.2508, 18)
            path.closeSubpath()
            path.move(7.75, 14)
            path.curve(7.75, 14.1381, 7.63807, 14.25, 7.5, 14.25)
            path.curve(7.36193, 14.25, 7.25, 14.1381, 7.25, 14)
            path.curve(7.25, 13.8619, 7.36193, 13.75, 7.5, 13.75)
            path.curve(7.63807, 13.75, 7.75, 13.8619, 7.75, 14)
            path.closeSubpath()
            path.move(7.75, 18)
            path.curve(7.75, 18.1381, 7.63807, 18.25, 7.5, 18.25)
            path.curve(7.36193, 18.25, 7.25, 18.1381, 7.25, 18)
            path.curve(7.25, 17.8619, 7.36193, 17.75, 7.5, 17.75)
            path.curve(7.63807, 17.75, 7.75, 17.8619, 7.75, 18)
            path.closeSubpath()
            path.move(16.75, 14)
            path.curve(16.75, 14.1381, 16.6381, 14.25, 16.5, 14.25)
            path.curve(16.3619, 14.25, 16.25, 14.1381, 16.25, 14)
            path.curve(16.25, 13.8619, 16.3619, 13.75, 16.5, 13.75)
            path.curve(16.6381, 13.75, 16.75, 13.8619, 16.75, 14)
            path.closeSubpath()

        case .launcher: // DashboardSquare01Icon.js
            path.move(13.6903, 19.4567)
            path.curve(13.5, 18.9973, 13.5, 18.4149, 13.5, 17.25)
            path.curve(13.5, 16.0851, 13.5, 15.5027, 13.6903, 15.0433)
            path.curve(13.944, 14.4307, 14.4307, 13.944, 15.0433, 13.6903)
            path.curve(15.5027, 13.5, 16.0851, 13.5, 17.25, 13.5)
            path.curve(18.4149, 13.5, 18.9973, 13.5, 19.4567, 13.6903)
            path.curve(20.0693, 13.944, 20.556, 14.4307, 20.8097, 15.0433)
            path.curve(21, 15.5027, 21, 16.0851, 21, 17.25)
            path.curve(21, 18.4149, 21, 18.9973, 20.8097, 19.4567)
            path.curve(20.556, 20.0693, 20.0693, 20.556, 19.4567, 20.8097)
            path.curve(18.9973, 21, 18.4149, 21, 17.25, 21)
            path.curve(16.0851, 21, 15.5027, 21, 15.0433, 20.8097)
            path.curve(14.4307, 20.556, 13.944, 20.0693, 13.6903, 19.4567)
            path.closeSubpath()

            path.move(13.6903, 8.95671)
            path.curve(13.5, 8.49728, 13.5, 7.91485, 13.5, 6.75)
            path.curve(13.5, 5.58515, 13.5, 5.00272, 13.6903, 4.54329)
            path.curve(13.944, 3.93072, 14.4307, 3.44404, 15.0433, 3.1903)
            path.curve(15.5027, 3, 16.0851, 3, 17.25, 3)
            path.curve(18.4149, 3, 18.9973, 3, 19.4567, 3.1903)
            path.curve(20.0693, 3.44404, 20.556, 3.93072, 20.8097, 4.54329)
            path.curve(21, 5.00272, 21, 5.58515, 21, 6.75)
            path.curve(21, 7.91485, 21, 8.49728, 20.8097, 8.95671)
            path.curve(20.556, 9.56928, 20.0693, 10.056, 19.4567, 10.3097)
            path.curve(18.9973, 10.5, 18.4149, 10.5, 17.25, 10.5)
            path.curve(16.0851, 10.5, 15.5027, 10.5, 15.0433, 10.3097)
            path.curve(14.4307, 10.056, 13.944, 9.56928, 13.6903, 8.95671)
            path.closeSubpath()

            path.move(3.1903, 19.4567)
            path.curve(3, 18.9973, 3, 18.4149, 3, 17.25)
            path.curve(3, 16.0851, 3, 15.5027, 3.1903, 15.0433)
            path.curve(3.44404, 14.4307, 3.93072, 13.944, 4.54329, 13.6903)
            path.curve(5.00272, 13.5, 5.58515, 13.5, 6.75, 13.5)
            path.curve(7.91485, 13.5, 8.49728, 13.5, 8.95671, 13.6903)
            path.curve(9.56928, 13.944, 10.056, 14.4307, 10.3097, 15.0433)
            path.curve(10.5, 15.5027, 10.5, 16.0851, 10.5, 17.25)
            path.curve(10.5, 18.4149, 10.5, 18.9973, 10.3097, 19.4567)
            path.curve(10.056, 20.0693, 9.56928, 20.556, 8.95671, 20.8097)
            path.curve(8.49728, 21, 7.91485, 21, 6.75, 21)
            path.curve(5.58515, 21, 5.00272, 21, 4.54329, 20.8097)
            path.curve(3.93072, 20.556, 3.44404, 20.0693, 3.1903, 19.4567)
            path.closeSubpath()

            path.move(3.1903, 8.95671)
            path.curve(3, 8.49728, 3, 7.91485, 3, 6.75)
            path.curve(3, 5.58515, 3, 5.00272, 3.1903, 4.54329)
            path.curve(3.44404, 3.93072, 3.93072, 3.44404, 4.54329, 3.1903)
            path.curve(5.00272, 3, 5.58515, 3, 6.75, 3)
            path.curve(7.91485, 3, 8.49728, 3, 8.95671, 3.1903)
            path.curve(9.56928, 3.44404, 10.056, 3.93072, 10.3097, 4.54329)
            path.curve(10.5, 5.00272, 10.5, 5.58515, 10.5, 6.75)
            path.curve(10.5, 7.91485, 10.5, 8.49728, 10.3097, 8.95671)
            path.curve(10.056, 9.56928, 9.56928, 10.056, 8.95671, 10.3097)
            path.curve(8.49728, 10.5, 7.91485, 10.5, 6.75, 10.5)
            path.curve(5.58515, 10.5, 5.00272, 10.5, 4.54329, 10.3097)
            path.curve(3.93072, 10.056, 3.44404, 9.56928, 3.1903, 8.95671)
            path.closeSubpath()

        case .clipboard: // Task01Icon.js
            path.move(14.4961, 2.00027)
            path.line(9.49609, 2.00027)
            path.curve(8.66767, 2.00027, 7.99609, 2.67185, 7.99609, 3.50027)
            path.curve(7.99609, 4.3287, 8.66767, 5.00027, 9.49609, 5.00027)
            path.line(14.4961, 5.00027)
            path.curve(15.3245, 5.00027, 15.9961, 4.3287, 15.9961, 3.50027)
            path.curve(15.9961, 2.67185, 15.3245, 2.00027, 14.4961, 2.00027)
            path.closeSubpath()

            path.move(7.99609, 15.0003)
            path.line(11.4247, 15.0003)
            path.move(7.99609, 11.0003)
            path.line(15.9961, 11.0003)

            path.move(15.9961, 3.50027)
            path.curve(17.5496, 3.54709, 18.4761, 3.72035, 19.1174, 4.36164)
            path.curve(19.9961, 5.24032, 19.9961, 6.65451, 19.9961, 9.4829)
            path.line(19.9961, 15.9997)
            path.curve(19.9961, 18.8282, 19.9961, 20.2424, 19.1174, 21.1211)
            path.curve(18.2387, 21.9997, 16.8245, 21.9997, 13.9961, 21.9997)
            path.line(9.99609, 21.9997)
            path.curve(7.16767, 21.9997, 5.75346, 21.9997, 4.87478, 21.1211)
            path.curve(3.9961, 20.2424, 3.9961, 18.8282, 3.99609, 15.9998)
            path.line(3.99611, 9.48296)
            path.curve(3.9961, 6.65453, 3.9961, 5.24031, 4.87478, 4.36163)
            path.curve(5.51606, 3.72034, 6.44261, 3.54708, 7.99599, 3.50027)

        case .shelf: // InboxIcon.js
            path.move(2.5, 12)
            path.curve(2.5, 7.52166, 2.5, 5.28249, 3.89124, 3.89124)
            path.curve(5.28249, 2.5, 7.52166, 2.5, 12, 2.5)
            path.curve(16.4783, 2.5, 18.7175, 2.5, 20.1088, 3.89124)
            path.curve(21.5, 5.28249, 21.5, 7.52166, 21.5, 12)
            path.curve(21.5, 16.4783, 21.5, 18.7175, 20.1088, 20.1088)
            path.curve(18.7175, 21.5, 16.4783, 21.5, 12, 21.5)
            path.curve(7.52166, 21.5, 5.28249, 21.5, 3.89124, 20.1088)
            path.curve(2.5, 18.7175, 2.5, 16.4783, 2.5, 12)
            path.closeSubpath()

            path.move(21.5, 13.5)
            path.line(16.5743, 13.5)
            path.curve(15.7322, 13.5, 15.0706, 14.2036, 14.6995, 14.9472)
            path.curve(14.2963, 15.7551, 13.4889, 16.5, 12, 16.5)
            path.curve(10.5111, 16.5, 9.70373, 15.7551, 9.30054, 14.9472)
            path.curve(8.92942, 14.2036, 8.26777, 13.5, 7.42566, 13.5)
            path.line(2.5, 13.5)

        case .shortcuts: // Copy01Icon.js
            path.move(7.5, 14.5)
            path.curve(7.5, 11.2002, 7.5, 9.55025, 8.52513, 8.52513)
            path.curve(9.55025, 7.5, 11.2002, 7.5, 14.5, 7.5)
            path.curve(17.7998, 7.5, 19.4497, 7.5, 20.4749, 8.52513)
            path.curve(21.5, 9.55025, 21.5, 11.2002, 21.5, 14.5)
            path.curve(21.5, 17.7998, 21.5, 19.4497, 20.4749, 20.4749)
            path.curve(19.4497, 21.5, 17.7998, 21.5, 14.5, 21.5)
            path.curve(11.2002, 21.5, 9.55025, 21.5, 8.52513, 20.4749)
            path.curve(7.5, 19.4497, 7.5, 17.7998, 7.5, 14.5)
            path.closeSubpath()

            path.move(7.5, 16.5)
            path.curve(6.10355, 16.5, 5.40533, 16.5, 4.84402, 16.3036)
            path.curve(3.83866, 15.9518, 3.0482, 15.1613, 2.69641, 14.156)
            path.curve(2.5, 13.5947, 2.5, 12.8964, 2.5, 11.5)
            path.line(2.5, 9.5)
            path.curve(2.5, 6.20017, 2.5, 4.55025, 3.52513, 3.52513)
            path.curve(4.55025, 2.5, 6.20017, 2.5, 9.5, 2.5)
            path.line(11.5, 2.5)
            path.curve(12.8964, 2.5, 13.5947, 2.5, 14.156, 2.69641)
            path.curve(15.1613, 3.0482, 15.9518, 3.83866, 16.3036, 4.84402)
            path.curve(16.5, 5.40533, 16.5, 6.10355, 16.5, 7.5)
        case .usage: // PieChart08Icon.js
            path.addEllipse(in: CGRect(x: 2, y: 2, width: 20, height: 20))
            path.addEllipse(in: CGRect(x: 7, y: 7, width: 10, height: 10))
            path.move(3.33984, 16.9996)
            path.line(7.66925, 14.5)
            path.move(16.3301, 14.5)
            path.line(20.6596, 16.9996)
            path.move(12, 2)
            path.line(12, 7)

        case .system: // Processor outline, matching the rounded 24-point tool grid.
            path.addRoundedRect(in: CGRect(x: 5, y: 5, width: 14, height: 14), cornerSize: CGSize(width: 3, height: 3))
            path.addRoundedRect(in: CGRect(x: 9, y: 9, width: 6, height: 6), cornerSize: CGSize(width: 1, height: 1))
            for position in [8.0, 12.0, 16.0] {
                path.move(position, 2); path.line(position, 5)
                path.move(position, 19); path.line(position, 22)
                path.move(2, position); path.line(5, position)
                path.move(19, position); path.line(22, position)
            }

        case .todo: // A checklist: two ticked rows and one still to do, on the rounded 24-point grid.
            for y in [5.5, 12.0] {
                path.move(3, y + 0.3); path.line(4.7, y + 2); path.line(7.6, y - 1.6)
                path.move(11.5, y + 0.2); path.line(21, y + 0.2)
            }
            path.addRoundedRect(in: CGRect(x: 3, y: 16.5, width: 4.6, height: 4.6), cornerSize: CGSize(width: 1.3, height: 1.3))
            path.move(11.5, 18.8); path.line(21, 18.8)

        case .inbox: // Notification01Icon.js
            path.move(15.5, 18)
            path.curve(15.5, 19.933, 13.933, 21.5, 12, 21.5)
            path.curve(10.067, 21.5, 8.5, 19.933, 8.5, 18)
            path.move(19.2311, 18)
            path.line(4.76887, 18)
            path.curve(3.79195, 18, 3, 17.208, 3, 16.2311)
            path.curve(3, 15.762, 3.18636, 15.3121, 3.51809, 14.9803)
            path.line(4.12132, 14.3771)
            path.curve(4.68393, 13.8145, 5, 13.0514, 5, 12.2558)
            path.line(5, 9.5)
            path.curve(5, 5.63401, 8.13401, 2.5, 12, 2.5)
            path.curve(15.866, 2.5, 19, 5.634, 19, 9.5)
            path.line(19, 12.2558)
            path.curve(19, 13.0514, 19.3161, 13.8145, 19.8787, 14.3771)
            path.line(20.4819, 14.9803)
            path.curve(20.8136, 15.3121, 21, 15.762, 21, 16.2311)
            path.curve(21, 17.208, 20.208, 18, 19.2311, 18)
            path.closeSubpath()
        }

        let scale = side / 24
        return path.applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - side / 2, ty: rect.midY - side / 2
        ))
    }
}

private extension Path {
    mutating func move(_ x: CGFloat, _ y: CGFloat) {
        move(to: CGPoint(x: x, y: y))
    }

    mutating func line(_ x: CGFloat, _ y: CGFloat) {
        addLine(to: CGPoint(x: x, y: y))
    }

    mutating func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        addCurve(
            to: CGPoint(x: x, y: y),
            control1: CGPoint(x: x1, y: y1),
            control2: CGPoint(x: x2, y: y2)
        )
    }
}
