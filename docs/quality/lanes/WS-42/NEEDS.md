# WS-42 needs from other lanes

## WS-43 (component row in `MP.maskDetail`, MaskPanel.swift ~1483)

Tapping a component row of a mask that is not the selected one sets `selectedMaskID`
directly. That selects the mask without telling the overlay, so no overlay shows and a
Show Overlay pin stays on the previously selected mask (breaks SPEC T12 on this path only).

Requested change, one line: when `mask.id != selectedMaskID`, call
`state.selectMask(mask.id)` (then set `selectedComponent` to the tapped index, since
`selectMask` resets it to 0). Every other selection path (row, rail, on-image pin,
duplicate) already goes through `selectMask`.
