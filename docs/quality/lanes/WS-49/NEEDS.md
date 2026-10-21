# WS-49 needs from other lanes

1. **Lens-profile alignment (RenderCoordinator / `AppState` matte ledger owner).**
   `matteSourceImage` renders `Recipe()`, whose `geometry.lens.profile` is `true`. A photo
   edited with the lens profile OFF is decoded uncorrected for its masks, but its matte was
   computed on the distortion-corrected frame: up to ~2% of the frame off at the corners on
   a wide m4/3 zoom. Fix: render the matte source with the recipe's own `lens.profile` and
   add that bool to the matte ledger's key (`attemptedMatteKinds`/`storeMattes` are per URL
   today), so toggling the profile regenerates. `matteSourceImage` would take a
   `lensProfile:` argument (WS-49 can add it); the cache-key and call-site change is in
   `RenderCoordinator.swift:577/666`, not WS-49's.
2. **Comment on `PipelineRenderer.maskRasterLongEdge` (WS-01/WS-25 region, ~2197).** Its
   doc says it is "also the resolution an AI matte is generated at". Since WS-49 that is
   `PipelineRenderer.matteLongEdge` (2048). One-line comment fix for the region owner.
3. **Sky model install UI (settings owner).** `SkyModel.shared.install(from:sha256:)`
   exists and nothing calls it, by design: no model with a shippable licence is chosen
   yet. When the owner hosts one, a settings row passes the URL and checksum.
