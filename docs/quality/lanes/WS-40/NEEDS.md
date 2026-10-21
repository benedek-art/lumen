# WS-40 Grain: needs outside the lane

Changes WS-40 needs in functions other lanes own. None of them blocks a SPEC line; each
is a follow-up for the owner.

## N1. Per-photo grain seed (WS-01, `PipelineRenderer` / `ReferenceRenderer.Inputs`)

Every photograph is grained from the same seed, `FilmGrainProfile.defaultPlateSeed`:
`ReferenceRenderer.Inputs.grainSeed` defaults to it and no caller sets it, and the GPU
builder is called without one. With the tiled plate this was hidden by the tile; with
procedural grain it means two frames of a burst carry the identical grain pattern, which
reads as a dirty sensor rather than as film when they are flipped between.

What is ready on the WS-40 side:
- `GrainPlan.field(longEdge:seed:)` takes the seed.
- `RenderGraph.grainPlate(_:extent:longEdge:seed:)` takes it too (default
  `defaultPlateSeed`, so no call site had to change).
- `ReferenceRenderer.applyGrain(_:grain:seed:longEdge:)` already took it.

Ask: derive a stable `UInt64` from the photo's identity (for example a hash of the
asset id) and pass it to all three call sites: `makeGraph`'s `graph.grainPlate`,
`exportedImage`'s grain, and the reference's `Inputs.grainSeed`. They must be the same
value, or the preview and the export draw different grain.

## N2. Stale comments about the plate's half-pixel floor (WS-01)

`PipelineRenderer.exportedImage` (around lines 1050-1080) and the grain block of
`RenderGraph.build` (around lines 318-350) explain the export deferral in terms of
`plateScale` and its half-pixel floor. There is no floor now: the grain field has a pixel
aperture, and a creative grain laid at the decode and then resampled is the same grain
as one laid after the resize, to within the aperture's approximation of a box filter
(SPEC line 8). The deferral is still right, because it puts the grain on the delivered
grid, but the comments describe a mechanism that no longer exists. No code change is
needed.

## N3. The Linux toolchain cannot run `swift test` (not a lane function)

With Swift 6.0.3 (`/opt/swift`), `swift build --build-tests` fails on the base commit
`397041b` as well: `Sources/LumenApp/CompareView.swift:326` and `:569` end an argument
list with a trailing comma, which Swift 6.0 does not parse, and Swift parses inactive
`#if os(macOS)` code. `swift test --filter LumenCoreTests` also overflows `posix_spawn`'s
argument list on this machine. The WS-40 runs used a local, uncommitted copy of
`CompareView.swift` with the two commas removed, and ran the test bundle directly
(`.build/x86_64-unknown-linux-gnu/debug/LumenPackageTests.xctest`). The owner of
`CompareView` should remove the two trailing commas, or the lane brief should name a
6.1 toolchain.

## N4. Local grain (WS-55)

`mask.adjust.grainAmount` can use the same engine: `GrainPlan.field` gives the field, and
`ReferenceRenderer.applyGrain` / `lumenGrain` apply it. A local amount is a per-pixel
scale of `amount`, which both implementations take as a scalar today.
