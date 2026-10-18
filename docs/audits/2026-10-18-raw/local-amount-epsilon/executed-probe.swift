
import Foundation
import LumenCore

struct LocalPlan {
    let preLUT: LUT3D?
    let colorStage: ExactColorStage
    let postLUT: LUT3D?
    let isIdentity: Bool

    /// `size` is the render's table size, not a default: an export bakes at
    /// `LUT3D.exportSize` and a preview at `LUT3D.interactiveSize`, and there is
    /// deliberately no default value here so that a new call site has to say which
    /// render it is baking for. Nothing caches this table — `PlanTableCache` refuses
    /// anything above the interactive size on purpose — so the size is not part of any
    /// cache key; it is baked once per mask per render, which at export is 274 625
    /// samples per mask instead of 35 937.
    /// `globalColor` and `globalWheels` are the GLOBAL panels' values, and they have
    /// no defaults for the same reason `size` has none: a call site that forgets them
    /// silently reverts COLOR-16/COLOR-27 — the masked grade re-zoned by factory
    /// pivots, the masked Sat re-protected by an invisible 70.
    init(adjust: LocalAdjust, scale: Double, whiteAnchorEV: Double,
         blackAnchorEV: Double, size: Int,
         globalColor: ColorAdjust, globalWheels: GradingWheels,
         balanced: WhiteBalanceEngine.Neutral) {
        // `pointColors` belongs in this list. Leaving it out meant a mask whose ONLY
        // edit was a sampled swatch declared itself identity, got a 2-point identity
        // table, and returned its input — the Point Colour control did nothing at all
        // inside a mask on the GPU path, which is every preview and every export.
        // Zero mask/group Amount nulls every adjustment delta. Bypass the table
        // domain entirely: even an identity cube clamps negative/extended channels.
        // Selection alpha and referenced donor masks are independent of this strength.
        let identity = scale == 0 || (adjust.contrast == 0 && adjust.highlights == 0
            && adjust.shadows == 0 && adjust.whites == 0 && adjust.blacks == 0
            && adjust.temp == 0 && adjust.tint == 0 && adjust.kelvin == nil
            && adjust.hue == 0
            && adjust.sat == 0 && adjust.vibrance == 0 && adjust.colorTint == nil
            && adjust.pointColors.isEmpty
            // `wheels` belongs here for the same reason `pointColors` does: a mask
            // whose only edit is a grade would otherwise declare itself identity and
            // return its input.
            && (adjust.wheels?.isNeutral ?? true))
        self.isIdentity = identity
        guard !identity else {
            self.preLUT = nil
            self.colorStage = ColorEngine(mixer: Mixer(), pointColors: [], color: ColorAdjust(),
                                          primaries: Primaries(), bw: nil).exactStage
            self.postLUT = nil
            return
        }

        let tone = ToneEngine(tone: Tone(contrast: adjust.contrast * scale,
                                         highlights: adjust.highlights * scale,
                                         shadows: adjust.shadows * scale,
                                         whites: adjust.whites * scale,
                                         blacks: adjust.blacks * scale))
        // Density and protectSkin inherited from the global colour panel — see
        // `ColorAdjust.local` (COLOR-27). Kept in lockstep with
        // `ReferenceRenderer.applyLocalAdjust`.
        let color = ColorAdjust.local(vibrance: adjust.vibrance * scale,
                                      saturation: adjust.sat * scale,
                                      inheriting: globalColor)
        let colorEngine = ColorEngine(
            mixer: Mixer(),
            pointColors: adjust.pointColors.map { $0.scalingShift(by: scale) },
            color: color, primaries: Primaries(), bw: nil)
        let hueShift = adjust.hue * scale
        let tintColor = adjust.colorTint
        let tintStrength = Num.clamp(adjust.colorTintStrength, 0, 100) / 100 * scale
        // Temp and Tint were in the identity test above and then never applied, so a
        // local white-balance nudge marked the stage live, rebuilt the table, and
        // produced the same picture.
        //
        // `resolve` rather than the relative initializer directly, because a mask now
        // has two spellings of white balance and exactly one place is allowed to decide
        // which one it is using. Two call sites choosing for themselves is how the
        // reference and the GPU start rendering different pictures from one recipe.
        let balance = ReferenceRenderer.LocalWhiteBalance.resolve(
            adjust, amount: scale, balanced: balanced, space: .rec2020)
        // Local grading wheels (D29). The panel has offered four draggable wheels
        // since it was written and no stage read them, so a masked grade moved
        // nothing. The anchors this needs were already parameters of this initializer
        // and were the only two it never used — they were plumbed here for exactly
        // this and left unconnected.
        //
        // Same engine as the global grade, never a parallel implementation: the zone
        // windows, the constant-luminance ab translation and the monotonicity solve
        // are the parts that make a grade look like a grade rather than a tint.
        let localGrade = (adjust.wheels?.isNeutral ?? true)
            ? nil
            // `adoptingWindows`: the mask's colour moves inside the GLOBAL wheels'
            // tonal windows — the docs/08 §8.4 contract (COLOR-16).
            : GradeEngine(wheels: adjust.wheels!.scalingShift(by: scale)
                              .adoptingWindows(from: globalWheels),
                          printerLights: PrinterLights(),
                          whiteAnchorEV: whiteAnchorEV, blackAnchorEV: blackAnchorEV)

        // Same identity tests the reference uses (`ReferenceRenderer.applyLocalAdjust`).
        self.preLUT = tone.isIdentity && balance.isIdentity ? nil : LUT3D(size: size) { encoded in
            var c = LumenLog.decode(encoded)
            let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
            return LumenLog.encode(balance.apply(c))
        }
        self.colorStage = colorEngine.exactStage
        let tinted = tintColor != nil && tintStrength > 0
        self.postLUT = hueShift == 0 && !tinted && localGrade == nil ? nil : LUT3D(size: size) { encoded in
            var c = LumenLog.decode(encoded)
            if hueShift != 0 {
                var lch = OKLabTransform.working.toLCh(c)
                lch.h = Num.wrapHue(lch.h + hueShift)
                c = OKLabTransform.working.toRGB(lch)
            }
            // One implementation, shared with the reference renderer — this used to be
            // a second copy here and nothing at all there.
            c = ReferenceRenderer.applyColorTint(c, tint: tintColor,
                                                 strength: tintStrength)
            // After the colour stage and the tint, matching where the global grade
            // sits relative to colour in the main plan (S9/S10).
            if let localGrade { c = localGrade.apply(c) }
            return LumenLog.encode(c)
        }
    }
}


struct LocalPlanWithoutZeroBypass {
    let preLUT: LUT3D?
    let colorStage: ExactColorStage
    let postLUT: LUT3D?
    let isIdentity: Bool

    /// `size` is the render's table size, not a default: an export bakes at
    /// `LUT3D.exportSize` and a preview at `LUT3D.interactiveSize`, and there is
    /// deliberately no default value here so that a new call site has to say which
    /// render it is baking for. Nothing caches this table — `PlanTableCache` refuses
    /// anything above the interactive size on purpose — so the size is not part of any
    /// cache key; it is baked once per mask per render, which at export is 274 625
    /// samples per mask instead of 35 937.
    /// `globalColor` and `globalWheels` are the GLOBAL panels' values, and they have
    /// no defaults for the same reason `size` has none: a call site that forgets them
    /// silently reverts COLOR-16/COLOR-27 — the masked grade re-zoned by factory
    /// pivots, the masked Sat re-protected by an invisible 70.
    init(adjust: LocalAdjust, scale: Double, whiteAnchorEV: Double,
         blackAnchorEV: Double, size: Int,
         globalColor: ColorAdjust, globalWheels: GradingWheels,
         balanced: WhiteBalanceEngine.Neutral) {
        // `pointColors` belongs in this list. Leaving it out meant a mask whose ONLY
        // edit was a sampled swatch declared itself identity, got a 2-point identity
        // table, and returned its input — the Point Colour control did nothing at all
        // inside a mask on the GPU path, which is every preview and every export.
        // Zero mask/group Amount nulls every adjustment delta. Bypass the table
        // domain entirely: even an identity cube clamps negative/extended channels.
        // Selection alpha and referenced donor masks are independent of this strength.
        let identity = (adjust.contrast == 0 && adjust.highlights == 0
            && adjust.shadows == 0 && adjust.whites == 0 && adjust.blacks == 0
            && adjust.temp == 0 && adjust.tint == 0 && adjust.kelvin == nil
            && adjust.hue == 0
            && adjust.sat == 0 && adjust.vibrance == 0 && adjust.colorTint == nil
            && adjust.pointColors.isEmpty
            // `wheels` belongs here for the same reason `pointColors` does: a mask
            // whose only edit is a grade would otherwise declare itself identity and
            // return its input.
            && (adjust.wheels?.isNeutral ?? true))
        self.isIdentity = identity
        guard !identity else {
            self.preLUT = nil
            self.colorStage = ColorEngine(mixer: Mixer(), pointColors: [], color: ColorAdjust(),
                                          primaries: Primaries(), bw: nil).exactStage
            self.postLUT = nil
            return
        }

        let tone = ToneEngine(tone: Tone(contrast: adjust.contrast * scale,
                                         highlights: adjust.highlights * scale,
                                         shadows: adjust.shadows * scale,
                                         whites: adjust.whites * scale,
                                         blacks: adjust.blacks * scale))
        // Density and protectSkin inherited from the global colour panel — see
        // `ColorAdjust.local` (COLOR-27). Kept in lockstep with
        // `ReferenceRenderer.applyLocalAdjust`.
        let color = ColorAdjust.local(vibrance: adjust.vibrance * scale,
                                      saturation: adjust.sat * scale,
                                      inheriting: globalColor)
        let colorEngine = ColorEngine(
            mixer: Mixer(),
            pointColors: adjust.pointColors.map { $0.scalingShift(by: scale) },
            color: color, primaries: Primaries(), bw: nil)
        let hueShift = adjust.hue * scale
        let tintColor = adjust.colorTint
        let tintStrength = Num.clamp(adjust.colorTintStrength, 0, 100) / 100 * scale
        // Temp and Tint were in the identity test above and then never applied, so a
        // local white-balance nudge marked the stage live, rebuilt the table, and
        // produced the same picture.
        //
        // `resolve` rather than the relative initializer directly, because a mask now
        // has two spellings of white balance and exactly one place is allowed to decide
        // which one it is using. Two call sites choosing for themselves is how the
        // reference and the GPU start rendering different pictures from one recipe.
        let balance = ReferenceRenderer.LocalWhiteBalance.resolve(
            adjust, amount: scale, balanced: balanced, space: .rec2020)
        // Local grading wheels (D29). The panel has offered four draggable wheels
        // since it was written and no stage read them, so a masked grade moved
        // nothing. The anchors this needs were already parameters of this initializer
        // and were the only two it never used — they were plumbed here for exactly
        // this and left unconnected.
        //
        // Same engine as the global grade, never a parallel implementation: the zone
        // windows, the constant-luminance ab translation and the monotonicity solve
        // are the parts that make a grade look like a grade rather than a tint.
        let localGrade = (adjust.wheels?.isNeutral ?? true)
            ? nil
            // `adoptingWindows`: the mask's colour moves inside the GLOBAL wheels'
            // tonal windows — the docs/08 §8.4 contract (COLOR-16).
            : GradeEngine(wheels: adjust.wheels!.scalingShift(by: scale)
                              .adoptingWindows(from: globalWheels),
                          printerLights: PrinterLights(),
                          whiteAnchorEV: whiteAnchorEV, blackAnchorEV: blackAnchorEV)

        // Same identity tests the reference uses (`ReferenceRenderer.applyLocalAdjust`).
        self.preLUT = tone.isIdentity && balance.isIdentity ? nil : LUT3D(size: size) { encoded in
            var c = LumenLog.decode(encoded)
            let lum = Swift.max(RGBColorSpace.rec2020.luminance(c), 0)
            c = c * tone.gain(at: Num.safeLog2(lum / 0.18))
            return LumenLog.encode(balance.apply(c))
        }
        self.colorStage = colorEngine.exactStage
        let tinted = tintColor != nil && tintStrength > 0
        self.postLUT = hueShift == 0 && !tinted && localGrade == nil ? nil : LUT3D(size: size) { encoded in
            var c = LumenLog.decode(encoded)
            if hueShift != 0 {
                var lch = OKLabTransform.working.toLCh(c)
                lch.h = Num.wrapHue(lch.h + hueShift)
                c = OKLabTransform.working.toRGB(lch)
            }
            // One implementation, shared with the reference renderer — this used to be
            // a second copy here and nothing at all there.
            c = ReferenceRenderer.applyColorTint(c, tint: tintColor,
                                                 strength: tintStrength)
            // After the colour stage and the tint, matching where the global grade
            // sits relative to colour in the main plan (S9/S10).
            if let localGrade { c = localGrade.apply(c) }
            return LumenLog.encode(c)
        }
    }
}


enum ProbeFailure: Error { case zeroIdentity, nonfinite, control }
func mapped(_ pixel: RGB, pre: LUT3D?, stage: ExactColorStage, post: LUT3D?, exposure: Double) -> RGB {
    var value = pixel * pow(2, exposure)
    if let pre { value = LumenLog.decode(pre.sample(LumenLog.encode(value))) }
    value = stage.apply(value)
    if let post { value = LumenLog.decode(post.sample(LumenLog.encode(value))) }
    return value
}
func run() throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    let pixels = [RGB(-0.01, 0.18, 0.3), RGB(1024, 128, 256), RGB(0.18, 0.3, 0.5), RGB(-0.0000001, 0.2, 0.3)]
    let amounts = [0.0, 1e-10, 0.0001, 0.01, 1.0]
    var rows = ["kind,axis,cube,requestedAmount,effectiveAmount,scale,pixel,alpha,inputR,inputG,inputB,tableR,tableG,tableB,directR,directG,directB,blendedR,blendedG,blendedB,maxTableInputDifference,maxDirectInputDifference,maxBlendedInputDifference,preLUT,postLUT"]
    var controls = ["cube,pixel,identityCubeR,identityCubeG,identityCubeB,zeroBypassDisabledR,zeroBypassDisabledG,zeroBypassDisabledB"]
    var zeroChecks = 0, finiteChecks = 0
    for cube in [17, 65] {
        for kind in ["grade", "exposure"] {
            for axis in ["mask", "group"] {
                for amount in amounts {
                    var mask = Mask(id: "epsilon", amount: axis == "mask" ? amount : 50)
                    if kind == "grade" {
                        var wheels = GradingWheels()
                        wheels.global = Wheel(hue: 123, sat: 0.4, lum: 0.1)
                        mask.adjust.wheels = wheels
                    } else { mask.adjust.exposure = 1 }
                    var recipe = Recipe()
                    recipe.develop.denoise.mode = .off
                    if axis == "group" {
                        mask.group = "g"
                        recipe.maskGroups = [MaskGroup(id: "g", amount: 2 * amount)]
                    }
                    recipe.masks = [mask]
                    // Global cube is not evaluated: this plan supplies actual group
                    // resolution, anchors and neutral. Local cubes use17/65 below.
                    let plan = RenderPlan(recipe: recipe, lutSize: 2)
                    let resolved = plan.masks[0]
                    let scale = Num.clamp(resolved.amount, 0, 200) / 100
                    let local = LocalPlan(adjust: resolved.adjust, scale: scale,
                        whiteAnchorEV: plan.tone.whiteAnchorEV, blackAnchorEV: plan.tone.blackAnchorEV,
                        size: cube, globalColor: recipe.develop.color, globalWheels: recipe.look.wheels,
                        balanced: plan.balancedNeutral)
                    let grade = resolved.adjust.wheels.map {
                        GradeEngine(wheels: $0.scalingShift(by: scale).adoptingWindows(from: recipe.look.wheels),
                            printerLights: PrinterLights(), whiteAnchorEV: plan.tone.whiteAnchorEV,
                            blackAnchorEV: plan.tone.blackAnchorEV)
                    }
                    for (ordinal, pixel) in pixels.enumerated() {
                        let table = mapped(pixel, pre: local.preLUT, stage: local.colorStage,
                                           post: local.postLUT, exposure: resolved.adjust.exposure * scale)
                        // Direct actualCoreGrade/exposure, source-equivalent for these
                        // two isolated controls; not execution of applyLocalAdjust.
                        let direct = grade?.apply(pixel) ?? pixel * pow(2, resolved.adjust.exposure * scale)
                        guard table.isFinite && direct.isFinite else { throw ProbeFailure.nonfinite }
                        finiteChecks += 1
                        if amount == 0 {
                            guard table == pixel && direct == pixel else { throw ProbeFailure.zeroIdentity }
                            zeroChecks += 1
                        }
                        for alpha in [0.0, 0.25, 0.75, 1.0] {
                            // Independent normal-alpha formula. There is no Amount
                            // factor here: Amount already scaled the subrecipe.
                            let blended = pixel * (1 - alpha) + table * alpha
                            let values: [String] = [kind, axis, String(cube), String(amount), String(resolved.amount), String(scale), String(ordinal), String(alpha),
                                String(pixel.r), String(pixel.g), String(pixel.b), String(table.r), String(table.g), String(table.b),
                                String(direct.r), String(direct.g), String(direct.b), String(blended.r), String(blended.g), String(blended.b),
                                String(table.maxAbsDifference(pixel)), String(direct.maxAbsDifference(pixel)), String(blended.maxAbsDifference(pixel)),
                                String(local.preLUT != nil), String(local.postLUT != nil)]
                            rows.append(values.joined(separator: ","))
                        }
                    }
                    if kind == "grade" && axis == "mask" && amount == 0 {
                        let disabled = LocalPlanWithoutZeroBypass(adjust: resolved.adjust, scale: 0,
                            whiteAnchorEV: plan.tone.whiteAnchorEV, blackAnchorEV: plan.tone.blackAnchorEV,
                            size: cube, globalColor: recipe.develop.color, globalWheels: recipe.look.wheels,
                            balanced: plan.balancedNeutral)
                        let identity = LUT3D(size: cube) { $0 }
                        for (ordinal, pixel) in pixels.enumerated() {
                            let cubeOnly = LumenLog.decode(identity.sample(LumenLog.encode(pixel)))
                            let oldZero = mapped(pixel, pre: disabled.preLUT, stage: disabled.colorStage,
                                                 post: disabled.postLUT, exposure: 0)
                            controls.append([String(cube), String(ordinal), String(cubeOnly.r), String(cubeOnly.g), String(cubeOnly.b),
                                             String(oldZero.r), String(oldZero.g), String(oldZero.b)].joined(separator: ","))
                        }
                    }
                }
            }
        }
    }
    try (rows.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("metrics.csv"), atomically: true, encoding: .utf8)
    try (controls.joined(separator: "\n") + "\n").write(to: output.appendingPathComponent("domain-controls.csv"), atomically: true, encoding: .utf8)
    let summary: [String: Any] = ["rows": rows.count - 1, "zeroIdentityChecks": zeroChecks, "finiteStagePairs": finiteChecks,
        "actualNativeGPUExecuted": false, "extractedLocalPlan": true, "independentNormalAlphaFormula": true,
        "lowerDomainEndpoint": LumenLog.decode(0), "upperDomainEndpoint": LumenLog.decode(1)]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
    print("LOCAL-AMOUNT-EPSILON rows=\(rows.count - 1) zeroExact=\(zeroChecks) finiteStagePairs=\(finiteChecks) GPUExecuted=false")
}
do { try run() }
catch { FileHandle.standardError.write(Data("LOCAL-AMOUNT-EPSILON failure=\(error)\n".utf8)); exit(1) }
