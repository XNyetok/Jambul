import SwiftUI
import Testing
@testable import Jambul

@MainActor
struct MotionTests {
    /// If the lift has slowed down by the time the hover intent ends, it stalls at the lifted size and opening reads
    /// as a second step after a pause. It has to still be moving close to top speed, even on the slow setting.
    @Test func theArrivalLiftIsStillMovingWhenTheIslandOpens() {
        let lift = Motion.arrivalLift
        let topSpeed = (0...1_000).map { lift.velocity(target: 1.0, time: Double($0) / 1_000) }.max() ?? 0
        for speed in HoverSpeed.allCases where speed.intent > .zero {
            let opensAt = speed.intent / .seconds(1)
            #expect(lift.velocity(target: 1.0, time: opensAt) >= 0.75 * topSpeed, "\(speed) stalls before opening")
        }
    }

    /// The island panel shrinks to fit the island once the island has settled. A spring still moving then would be cut
    /// off at the panel's edge.
    @Test func everyIslandSpringSettlesBeforeThePanelFitsTheIsland() {
        let presentations: [IslandPresentation] = [.idle, .compact, .lifted, .peek, .expanded]
        let settles = Motion.islandSettles / .seconds(1)
        for from in presentations {
            for to in presentations {
                let spring = Motion.spring(from: from, to: to)
                #expect(spring.settlingDuration <= settles, "\(from) → \(to) settles in \(spring.settlingDuration) s")
            }
        }
    }
}
