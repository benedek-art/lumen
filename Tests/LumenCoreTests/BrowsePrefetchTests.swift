// BrowsePrefetchTests.swift
// The cache level a request lands in, and the levels a cursor move warms, asserted
// against each other.
//
// This is the test that did not exist while the loupe asked the browse cache for 1600
// pixels — the 2048 level — and the only ring that ran while the loupe was on screen
// warmed 256. Both numbers were correct in their own file. Nothing compared them,
// because the ladder was a private constant in an AppKit file with no test target.

import XCTest
@testable import LumenCore

final class BrowsePrefetchTests: XCTestCase {

    // MARK: The ladder

    func testEveryRequestSnapsUpToACacheLevel() {
        for size in 1...2400 {
            let level = ThumbnailLadder.bucket(for: size)
            XCTAssertTrue(ThumbnailLadder.levels.contains(level),
                          "\(size) snapped to \(level), which is not a cache level")
            if level != ThumbnailLadder.levels.last {
                XCTAssertGreaterThanOrEqual(level, size,
                                            "\(size) snapped DOWN to \(level)")
            }
        }
    }

    func testTheLoupeInstantRequestLandsInTheTopBucket() {
        // The units mismatch itself, pinned: 1600 is not a level, it is a request that
        // resolves to one, and it resolves to the most expensive one there is.
        XCTAssertFalse(ThumbnailLadder.levels.contains(ThumbnailLadder.loupeInstantPixels))
        XCTAssertEqual(ThumbnailLadder.loupeBucket, 2048)
        XCTAssertEqual(ThumbnailLadder.bucket(for: ThumbnailLadder.loupeInstantPixels),
                       ThumbnailLadder.loupeBucket)
    }

    // MARK: Which levels a cursor move warms

    func testEverySurfaceThatPagesTheLoupeWarmsTheLoupeLevel() {
        // The defect: the strip warmed its own 256 and nothing else, so every advance
        // in the loupe found the 2048 bucket empty and paid a cold embedded-JPEG decode
        // before the pipeline started.
        for surface in [PagingSurface.filmstrip, .loupe] {
            for browse in [64, 256, 320, 512, 1024] {
                let warmed = ThumbnailLadder.warmSizes(for: surface, browsePixels: browse)
                XCTAssertTrue(warmed.contains(ThumbnailLadder.loupeBucket),
                              "\(surface) at \(browse) warms \(warmed), "
                                  + "which does not include the level the loupe reads")
            }
        }
    }

    func testTheFilmstripWarmsItsOwnVisibleCellsFirst() {
        // Order is priority: the strip's cells are on screen now, the loupe level is a
        // bet on the next keystroke. Warming the heavy level first would let 2048
        // decodes occupy all eight workers while the visible strip stayed grey.
        let warmed = ThumbnailLadder.warmSizes(for: .filmstrip, browsePixels: 256)
        XCTAssertEqual(warmed.first, 256)
        XCTAssertEqual(warmed, [256, 2048])
    }

    func testASurfaceNeverAsksForTheSameLevelTwice() {
        for surface in PagingSurface.allCases {
            for browse in [64, 256, 320, 512, 1024, 1600, 2048, 4096] {
                let warmed = ThumbnailLadder.warmSizes(for: surface, browsePixels: browse)
                XCTAssertEqual(Set(warmed).count, warmed.count,
                               "\(surface) at \(browse) warms \(warmed) twice over")
                XCTAssertFalse(warmed.isEmpty)
                for level in warmed {
                    XCTAssertTrue(ThumbnailLadder.levels.contains(level),
                                  "\(surface) asked for \(level), not a cache level")
                }
            }
        }
    }

    func testTheGridDoesNotWarmTheLoupeLevel() {
        // The contact sheet's own scroll is the tightest budget in the app and it
        // shares eight decode workers with everything else. A grid cell is at most 512
        // points, so at 2× it asks for 1024 and must stay there.
        for browse in [192, 320, 640, 1024] {
            XCTAssertEqual(ThumbnailLadder.warmSizes(for: .grid, browsePixels: browse),
                           [ThumbnailLadder.bucket(for: browse)])
        }
        XCTAssertFalse(ThumbnailLadder.warmSizes(for: .grid, browsePixels: 1024)
            .contains(ThumbnailLadder.loupeBucket))
    }

    func testTheLoupeWarmsExactlyOneLevelWhateverSizeItIsHanded() {
        // The viewer's level is a property of the viewer. Reading it off whatever size
        // the caller passed is precisely how the two drifted apart.
        for browse in [1, 256, 999, 1600, 4096] {
            XCTAssertEqual(ThumbnailLadder.warmSizes(for: .loupe, browsePixels: browse),
                           [ThumbnailLadder.loupeBucket])
        }
    }

    // MARK: The ring

    private let ring = PrefetchRing(ahead: 8, behind: 2)

    func testTheRingIsEightAheadAndTwoBehindTheCursor() {
        let window = ring.window(anchor: 20, count: 100, direction: 1)
        XCTAssertEqual(window.ahead, [20, 21, 22, 23, 24, 25, 26, 27, 28])
        XCTAssertEqual(window.behind, [19, 18])
    }

    func testTheRingLeadsWithTheFrameUnderTheCursor() {
        for direction in [1, -1] {
            let window = ring.window(anchor: 40, count: 100, direction: direction)
            XCTAssertEqual(window.ahead.first, 40)
        }
    }

    func testReversingTravelReAimsTheWindow() {
        let backward = ring.window(anchor: 20, count: 100, direction: -1)
        XCTAssertEqual(backward.ahead, [20, 19, 18, 17, 16, 15, 14, 13, 12])
        XCTAssertEqual(backward.behind, [21, 22])
    }

    func testTheWindowIsClampedToTheListAtBothEnds() {
        let head = ring.window(anchor: 0, count: 5, direction: -1)
        XCTAssertEqual(head.ahead, [0])
        XCTAssertEqual(head.behind, [1, 2])

        let tail = ring.window(anchor: 4, count: 5, direction: 1)
        XCTAssertEqual(tail.ahead, [4])
        XCTAssertEqual(tail.behind, [3, 2])
    }

    func testTheWindowNeverNamesTheSameFrameTwice() {
        for count in 1...12 {
            for anchor in 0..<count {
                for direction in [1, -1] {
                    let window = ring.window(anchor: anchor, count: count,
                                             direction: direction)
                    let all = window.ahead + window.behind
                    XCTAssertEqual(Set(all).count, all.count,
                                   "anchor \(anchor) of \(count) going \(direction) "
                                       + "asks for \(all)")
                    for index in all {
                        XCTAssertTrue((0..<count).contains(index))
                    }
                }
            }
        }
    }

    func testAnAnchorOutsideTheListWarmsNothing() {
        XCTAssertTrue(ring.window(anchor: 5, count: 5, direction: 1).ahead.isEmpty)
        XCTAssertTrue(ring.window(anchor: -1, count: 5, direction: 1).ahead.isEmpty)
        XCTAssertTrue(ring.window(anchor: 0, count: 0, direction: 1).ahead.isEmpty)
    }

    func testTravelDirectionFollowsTheCursorAndHoldsWhenItDoesNotMove() {
        XCTAssertEqual(PrefetchRing.direction(from: 10, to: 11, current: -1), 1)
        XCTAssertEqual(PrefetchRing.direction(from: 11, to: 10, current: 1), -1)
        // A second view aiming the same ring at the same cursor, and a key held down on
        // the last frame, must both leave the direction alone.
        XCTAssertEqual(PrefetchRing.direction(from: 10, to: 10, current: -1), -1)
        XCTAssertEqual(PrefetchRing.direction(from: nil, to: 10, current: -1), -1)
        XCTAssertEqual(PrefetchRing.direction(from: nil, to: 10, current: 1), 1)
    }
}
