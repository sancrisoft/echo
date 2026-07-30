//
//  FinalPassTierTests.swift
//  EchoTests
//
//  SP-005 S5 (ADR-015): the RAM-tier decision as a pure table — physical
//  memory in, tier out (Testing Decisions, layer 1). The boundary rows pin
//  the 15.0 GiB tolerance: a real "16 GB" machine reporting slightly under
//  16 GiB must land in the full tier, while the nearest configurations below
//  (8 and 12 GB) stay on the reuse-live floor.
//

import Foundation
import Testing
@testable import Echo

@Suite("FinalPassTier (ADR-015)")
struct FinalPassTierTests {

    private let gib: UInt64 = 1_073_741_824

    @Test("8 GiB machines reuse the live model")
    func eightGiBReusesLive() {
        #expect(FinalPassTier.tier(forPhysicalMemory: 8 * gib) == .reuseLive)
    }

    @Test("12 GiB machines reuse the live model")
    func twelveGiBReusesLive() {
        #expect(FinalPassTier.tier(forPhysicalMemory: 12 * gib) == .reuseLive)
    }

    @Test("16 GiB and above run the full large-v3 tier")
    func sixteenGiBAndAboveRunFull() {
        for gigabytes in [16, 18, 24, 32, 64] as [UInt64] {
            #expect(
                FinalPassTier.tier(forPhysicalMemory: gigabytes * gib) == .fullLargeV3,
                "\(gigabytes) GiB"
            )
        }
    }

    @Test("the 15.0 GiB tolerance boundary is inclusive")
    func toleranceBoundaryIsInclusive() {
        let threshold = FinalPassTier.fullTierMinimumBytes
        #expect(threshold == 15 * gib)
        #expect(FinalPassTier.tier(forPhysicalMemory: threshold) == .fullLargeV3)
        #expect(FinalPassTier.tier(forPhysicalMemory: threshold - 1) == .reuseLive)
    }

    @Test("a 16 GB machine with a firmware carve-out still counts as 16 GB class")
    func sixteenGBWithCarveOutCountsAsFull() {
        // Half a GiB reserved below the marketed size — the case the
        // tolerance exists for.
        let reported = 16 * gib - 512 * 1_048_576
        #expect(FinalPassTier.tier(forPhysicalMemory: UInt64(reported)) == .fullLargeV3)
    }

    @Test("zero and tiny memory read as the floor tier")
    func degenerateInputsReadAsFloor() {
        #expect(FinalPassTier.tier(forPhysicalMemory: 0) == .reuseLive)
        #expect(FinalPassTier.tier(forPhysicalMemory: 1) == .reuseLive)
    }
}
