// Hugeicons Free Stroke Rounded, @hugeicons/core-free-icons v4.4.0.
// Copyright (c) 2026 Hugeicons. MIT License.
// Source: https://cdn.jsdelivr.net/npm/@hugeicons/core-free-icons@4.4.0/dist/esm/
// Each case below names its original asset. Geometry is preserved on the 24-point grid.

import SwiftUI

enum ToolIcon: CaseIterable {
    case ask, timer, prompter, today, clipboard, shelf, shortcuts
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
