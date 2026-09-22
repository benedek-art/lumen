# Executed tests

| Run | Tests | Skipped | Failing tests |
|---|---:|---:|---:|
| Main, debug, ControlProofTests excluded | 2321 | 12 | 1 |
| Main, optimized 135-control proof registry | 6 | 0 | 0 |
| Newer branch, optimized full suite | 2398 | 14 | 1 |

Main's one failing test is the platform-dependent grade hash test; it is fixed on the newer branch. Main also logged 32 accepted expected-failure assertions across 26 test methods. Those are not 32 newly discovered bugs; they include historical boundary cases and floating-point exactness limitations. Twelve skips are eleven standard RAW-corpus tests (corpus environment unset) and one opt-in CPU speed benchmark. Independent probes used all three supplied RAW copies instead of claiming the standard multi-camera corpus ran.

Detailed logs and machine-readable counts: see evidence/ and test-results.json.

## Main's accepted expected failures

- Test Case '-[LumenCoreTests.CurveAdversarialTests testAZeroBandComesHomeToExactlyZero]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:373: XCTAssertEqual failed: ("7.105427357601002e-15") is not equal to ("0.0") - 0 came back as -7.105427357601002e-15 after [0.0, -17.37, 2.36, 32.81, -44.16, 70.26, 81.45, 100.0] by -17.82

- Test Case '-[LumenCoreTests.CurveAdversarialTests testGroupMoveIsRigidForEveryInRangeSet]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:337: XCTAssertTrue failed - 104561 failures, first: [38.41, 85.01, 8.85, -67.95, 36.09, -41.56, -87.63, 66.54] by 249.77 -> [53.39999999999999, 100.0, 23.839999999999996, -52.96000000000001, 51.08, -26.570000000000007, -72.64, 81.53]: member 2 shifted 14.989999999999997 not 14.989999999999995

- Test Case '-[LumenCoreTests.CurveAdversarialTests testGroupMoveOnASpreadWiderThanTheRange]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:427: XCTAssertFalse failed - [-150.0, 150.0] is frozen in BOTH directions (up 0.0, down -0.0) — the row cannot be dragged back into range

- Test Case '-[LumenCoreTests.CurveAdversarialTests testGroupMoveOnValuesOutsideTheRange]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:405: XCTAssertEqualWithAccuracy failed: ("110.0") is not equal to ("150.0") +/- ("1e-09") - moved([150.0, 0.0], by: -10) = [100.0, -10.0]: the spread changed from 150.0 to 110.0

- Test Case '-[LumenCoreTests.CurveAdversarialTests testGroupMoveOnValuesOutsideTheRange]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:409: XCTAssertEqual failed: ("[100.0, -10.0]") is not equal to ("[150.0, 0.0]") - [150.0, 0.0] -> [100.0, -10.0] -> [100.0, -10.0] is not reversible

- Test Case '-[LumenCoreTests.CurveAdversarialTests testGroupMoveToARailAndBackIsBitForBit]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:304: XCTAssertTrue failed - 102614 failures, first: round trip off by 8.881784197001252e-16: -5.96 -> -5.960000000000001 [[38.56, -5.96, 77.44, -33.11, -9.51, 49.18] by 200.0, applied 22.560000000000002]

- Test Case '-[LumenCoreTests.CurveAdversarialTests testMeanAndMovedAgreeAboutWhichSetsAreLive]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:450: XCTAssertNotEqual failed: ("[10.0, nan, -10.0, 0.0, 0.0, 0.0, 0.0, 0.0]") is equal to ("[10.0, nan, -10.0, 0.0, 0.0, 0.0, 0.0, 0.0]") - the row displays 0.0 but every drag is refused: allowed() = 0.0

- Test Case '-[LumenCoreTests.CurveAdversarialTests testTwoDeletionsAtOneIndexAreTwoUndoSteps]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at CurveAdversarialTests.swift:509: XCTAssertFalse failed - two ⌥-clicks removing two different points folded into ONE undo step

- Test Case '-[LumenCoreTests.IngestAdversarialTests testACancelledRunStillNamesTheDestinationThatFailed]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:315: XCTAssertTrue failed - a stopped run with a failed destination reported only: Stopped after 1 of 2 frames — nothing was left half-written.

- Test Case '-[LumenCoreTests.IngestAdversarialTests testAFrameThatShrinksAfterThePlanIsNotReportedAsShort]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:229: XCTAssertEqual failed: ("5000") is not equal to ("-1") - the report claims 5000 bytes copied, -1 bytes are on disk

- Test Case '-[LumenCoreTests.IngestAdversarialTests testAFrameWithNoDestinationCannotCountAsVerified]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:340: XCTAssertEqual failed: ("200") is not equal to ("0") - nothing was written anywhere and the report claims 200 bytes

- Test Case '-[LumenCoreTests.IngestAdversarialTests testATwinFrameThatWasAbsorbedDoesNotUnlockEject]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:593: XCTAssertFalse failed - two frames on the card, ["2026/wedding.RAF"] on the volume, and the card may be ejected: Ingested 2 frames, every copy verified. · 1 already on disk

- Test Case '-[LumenCoreTests.IngestAdversarialTests testBytesCopiedDoesNotCountAFrameThatFailedEverywhere]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:284: XCTAssertEqual failed: ("7400") is not equal to ("400") - one 400-byte frame landed; the report claims 7400 bytes: Ingested 2 of 2 frames — 1 failed — BAD00001.RAF → primary: could not be read from the source: The file “BAD00001.RAF” doesn’t exist.

- Test Case '-[LumenCoreTests.IngestAdversarialTests testBytesCopiedDoesNotCountFramesThatWereAlreadyPresent]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:253: XCTAssertEqual failed: ("900") is not equal to ("0") - nothing was copied, and the report says 900 bytes were: Ingested 1 frame, every copy verified. · 1 already on disk

- Test Case '-[LumenCoreTests.IngestAdversarialTests testEveryReIngestOfARenamedFrameAddsAnotherCopy]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:572: XCTAssertEqual failed: ("4") is not equal to ("2") - three ingests of the same one-frame card left ["2026/GROW0001-1.RAF", "2026/GROW0001-2.RAF", "2026/GROW0001-3.RAF", "2026/GROW0001.RAF"]

- Test Case '-[LumenCoreTests.IngestAdversarialTests testReIngestAfterADisambiguationDoesNotDuplicateTheFrame]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:375: XCTAssertEqual failed: ("0") is not equal to ("1") - the frame was already on the volume and the second run reported: Ingested 1 frame, every copy verified. · 1 renamed to avoid overwriting

- Test Case '-[LumenCoreTests.IngestAdversarialTests testReIngestAfterADisambiguationDoesNotDuplicateTheFrame]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:378: XCTAssertEqual failed: ("3") is not equal to ("2") - after two runs of a one-frame card the volume holds ["2026/SAME0001-1.RAF", "2026/SAME0001-2.RAF", "2026/SAME0001.RAF"]: Ingested 1 frame, every copy verified. · 1 renamed to avoid overwriting

- Test Case '-[LumenCoreTests.IngestAdversarialTests testReIngestAfterADisambiguationDoesNotDuplicateTheFrame]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:381: XCTAssertEqual failed: ("700") is not equal to ("0") - Ingested 1 frame, every copy verified. · 1 renamed to avoid overwriting

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTheProgressBarDoesNotCountFramesThatNeverLanded]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:545: XCTAssertEqual failed: ("Optional(10000)") is not equal to ("Optional(400)") - the bar finished at 10000 bytes with 400 bytes on the volume: Ingested 2 of 2 frames — 1 failed — PRG00002.RAF → primary: could not be read from the source: The file “PRG00002.RAF” doesn’t exist.

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTheProgressBarDoesNotCountFramesThatNeverLanded]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:548: XCTAssertLessThan failed: ("1.0") is not less than ("1.0") - the bar reached 100% for a run that lost a frame

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTheSummaryDoesNotSayItIngestedAFrameThatFailed]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:646: XCTAssertFalse failed - one frame of two landed and the sentence is: Ingested 2 of 2 frames — 1 failed — SUM00002.RAF → primary: could not be read from the source: The file “SUM00002.RAF” doesn’t exist.

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTwoIdenticalFramesUnderOneRenderedNameBothSurvive]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:404: XCTAssertEqual failed: ("1") is not equal to ("2") - two frames were planned and the volume holds ["2026/wedding.RAF"]: Ingested 2 frames, every copy verified. · 1 already on disk

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTwoRootsThatAreOneDirectoryAreNotReportedAsTwoCopies]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:618: XCTAssertEqual failed: ("2") is not equal to ("1") - one volume holds ["2026/LNK00001-1.RAF", "2026/LNK00001.RAF"] for a one-frame card: Ingested 1 frame, every copy verified. · 1 renamed to avoid overwriting

- Test Case '-[LumenCoreTests.IngestAdversarialTests testTwoRootsThatAreOneDirectoryAreNotReportedAsTwoCopies]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at IngestAdversarialTests.swift:620: XCTAssertFalse failed - a backup that is the primary reported: Ingested 1 frame, every copy verified. · 1 renamed to avoid overwriting

- Test Case '-[LumenAppTests.LayoutMetricTests testTheCoarseTrackClearsThePrecisionFloorAtTheDefaultPanelWidth]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at LayoutMetricTests.swift:211: failed - LumenControls.swift: the default width exists to buy "~1.0" points of track travel per unit.

- Test Case '-[LumenAppTests.LayoutMetricTests testTheCoarseTrackClearsThePrecisionFloorAtTheMinimumPanelWidth]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at LayoutMetricTests.swift:247: failed - LumenControls.swift: "under the ~1.0 at which a one-pixel tremor stops costing a whole unit".

- Test Case '-[LumenAppTests.LayoutMetricTests testTheNarrowestTrackCanAddressEveryIntegerOfABipolarHundredControl]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at LayoutMetricTests.swift:297: XCTAssertGreaterThanOrEqual failed: ("0.71") is less than ("1.0") - a ±100 slider in a fold at the minimum column has 142.0 pt of track — 0.710 pt per unit, so only about 143 of its 201 integers are reachable by dragging. The chain: 320.0 column − 8.0 scroll − 20.0 card − 0.0 fold − 150.0 row chrome (label 86.0 + 2×6 gaps + readout 52.0). Clearing it needs 200 pt of track, i.e. a 378.0 pt column — every inset in the chain above is already spent

- Test Case '-[LumenCoreTests.MaskDependencyAdversarialTests testTwoMasksCarryingOneIdentityLeaveTheSecondOnesDependencyUnfetched]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at MaskDependencyAdversarialTests.swift:569: XCTAssertEqual failed: ("["src", "dup", "dup"]") is not equal to ("["dup", "dup"]") - the walk resolved "dup" to the first row's components, so the Subject mask the second row points at is not in the roster

- Test Case '-[LumenCoreTests.MaskDependencyAdversarialTests testTwoMasksCarryingOneIdentityLeaveTheSecondOnesDependencyUnfetched]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at MaskDependencyAdversarialTests.swift:574: XCTAssertEqual failed: ("[LumenCore.MaskKind.aiSubject]") is not equal to ("[]") - the matte the second row's reference needs was never asked for

- Test Case '-[LumenCoreTests.RollCursorAdversarialTests testAVerifiedHitReturnsANonFirstIndexOnceTheRollCarriesTheFileTwice]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at RollCursorAdversarialTests.swift:55: XCTAssertEqual failed: ("Optional(2)") is not equal to ("Optional(0)") - the memo answered Optional(2) where the search it replaces answers Optional(0)

- Test Case '-[LumenCoreTests.RollCursorAdversarialTests testTheFastPathDisagreesWithFirstIndexAfterADuplicateAppearsBeforeIt]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at RollCursorAdversarialTests.swift:82: XCTAssertEqual failed: ("Optional(1)") is not equal to ("Optional(0)") - answered Optional(1) for a roll whose first index is 0

- Test Case '-[LumenCoreTests.RollCursorAdversarialTests testTwoCursorsDisagreeAboutTheSameRoll]' started.
  XCTExpectFailure: matcher accepted Assertion Failure at RollCursorAdversarialTests.swift:111: XCTAssertEqual failed: ("Optional(1)") is not equal to ("Optional(0)") - the answer depends on the cursor's history, not on the roll


## Newer branch result and independent rerun

The optimized full suite executed 2,398 tests with 14 skips and one failing timing assertion. The two additional skips are opt-in control registry/probe utilities; the other twelve are the same corpus/benchmark skips described above. Main's grade-hash failure is fixed and passes here.

The new failure is PlanCostProbeTests.testATableRekeyingDragDoesNotPayTheBakePerFrame, line149. The test requires draft cost below25% of settle cost. Full-suite result: draft1.025875ms versus a0.994198ms threshold. An isolated optimized rerun, with the audit UI closed, also failed: draft1.293042ms versus a1.20702075ms threshold (settle4.828083ms; ratio26.8%). The rerun ran two tests with one failure. Thus the configured performance target is not met on this machine in either run; this is not evidence of a colour-error or a visibly unusable slider. No full-suite green result is claimed. Both logs are preserved.

The latest branch was built and its full suite executed by the coordinating audit. Sub-audits' branch-persistence statements remain source comparisons, not claims that every bespoke probe was repeated on that branch.
