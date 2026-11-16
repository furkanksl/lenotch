import QuartzCore
import XCTest
@testable import SpacesEngine

final class DesktopTransitionRenderingTests: XCTestCase {
    func testAnimationFramesKeepCardGeometryAndShadowPathStable() {
        let card = TransitionCard()
        let size = CGSize(width: 1728, height: 1117)
        card.layout(size: size, cornerRadius: 14)
        let originalPath = card.container.shadowPath
        XCTAssertNotNil(originalPath)

        for frame in 0..<240 {
            // Repeated layouts must not invalidate full-screen geometry and shadow paths.
            card.layout(size: size, cornerRadius: 14)
            card.apply(CardPlacement(hidden: false, position: CGPoint(x: frame * 8, y: 0),
                                     transform: CATransform3DMakeScale(0.94, 0.94, 1), dim: 0.1))
            XCTAssertTrue(card.container.shadowPath === originalPath)
            XCTAssertEqual(card.container.bounds.size, size)
        }
    }

    func testScreenOrCornerPreferenceChangesUpdateTheGeometry() {
        let card = TransitionCard()
        card.layout(size: CGSize(width: 1728, height: 1117), cornerRadius: 14)
        let rounded = card.container.shadowPath
        card.layout(size: CGSize(width: 1728, height: 1117), cornerRadius: 0)
        XCTAssertFalse(card.container.shadowPath === rounded)

        card.layout(size: CGSize(width: 2560, height: 1440), cornerRadius: 0)
        XCTAssertEqual(card.container.shadowPath?.boundingBox, CGRect(x: 0, y: 0, width: 2560, height: 1440))
        XCTAssertEqual(card.container.bounds.size, CGSize(width: 2560, height: 1440))
    }

    func testPrismTransformsDoNotRelayoutTheirSurfaces() {
        let card = TransitionCard()
        let size = CGSize(width: 1728, height: 1117)
        card.layout(size: size, cornerRadius: 0)
        let originalPath = card.container.shadowPath
        for frame in 0...120 {
            var transform = CATransform3DIdentity
            transform.m34 = -1 / (size.width * 2)
            transform = CATransform3DRotate(transform, CGFloat(frame) / 120 * .pi / 3, 0, 1, 0)
            card.apply(CardPlacement(hidden: false, position: CGPoint(x: size.width / 2, y: size.height / 2),
                                     transform: transform, dim: 0.1))
            XCTAssertTrue(card.container.shadowPath === originalPath)
            XCTAssertEqual(card.container.bounds.size, size)
        }
    }

    func testScriptedMotionEndsAtItsLastFrameAndHoldsItsFirst() {
        let card = TransitionCard()
        card.layout(size: CGSize(width: 1728, height: 1117), cornerRadius: 14)
        let frames: [CardPlacement] = (0...4).map { (step: Int) -> CardPlacement in
            let remaining = CGFloat(4 - step)
            let scale: CGFloat = 0.9 + CGFloat(step) * 0.025
            return CardPlacement(hidden: step == 0, position: CGPoint(x: remaining * 100, y: 50),
                                 transform: CATransform3DMakeScale(scale, scale, 1), dim: Float(remaining) / 10)
        }
        let keyTimes = (0...4).map { NSNumber(value: Double($0) / 4) }
        let discrete = (0...5).map { NSNumber(value: min(Double($0) / 4, 1)) }
        card.animate(frames, keyTimes: keyTimes, discreteKeyTimes: discrete, duration: 0.4, beginTime: 10)

        // The model is the end of the motion, so removing the animation never jumps.
        XCTAssertEqual(card.container.position, CGPoint(x: 0, y: 50))
        XCTAssertFalse(card.container.isHidden)
        let position = card.container.animation(forKey: "\(TransitionCard.animationKey).position") as? CAKeyframeAnimation
        XCTAssertEqual(position?.values?.count, 5)
        XCTAssertEqual(position?.fillMode, .backwards, "Before the render server starts it, the first frame must show")
        let hidden = card.container.animation(forKey: "\(TransitionCard.animationKey).hidden") as? CAKeyframeAnimation
        XCTAssertEqual(hidden?.calculationMode, .discrete)
        XCTAssertEqual(hidden?.keyTimes?.count, 6, "Discrete keyframes need one more key time than values")
        XCTAssertNil(card.container.animation(forKey: "\(TransitionCard.animationKey).zPosition"), "Constant values are not animated")

        card.stopAnimating()
        XCTAssertNil(card.container.animationKeys())
    }
}
