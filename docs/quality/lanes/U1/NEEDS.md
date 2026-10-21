# U1 needs from other lanes

The tokens exist in `enum Lumen` (`LumenControls.swift`, "Spacing (U1)"). These are the
places outside U1's files where they should be used, measured on the baseline set.

1. **LumenMenu (Film Lab stock, crop guides).** The stock menu's trailing edge is at
   x 718 px against the value pills' 732 (`panel-grade-film-lab-stock.png`): 7 pt short
   of the column every other row ends on. It should fill to the content edge.
2. **T2, curve editor in the masking column.** The Param/Point/R/G/B/Luma segmented
   control and the plot start at x 44 px against the labels' 28 + 12 (now 40 + 0 with
   the new card padding): an extra 8 pt inset inside the card (`column-masking.png`
   y 1336). Drop the editor's own horizontal padding; the card supplies it.
3. **U2, `LumenSlider`.** The row's focus fill now reaches `Lumen.rowHighlightOutset`
   past the row (done in `lumenFocusSurface`, which is shared). If U2 adds any other
   fill to the row (pressed, scrubbing), use the same outset so the shapes match.
4. **Develop footer (Auto, Reset, Undo, Redo / Copy, Paste / Copy Look, Paste Look).**
   4 + 2 + 2 buttons centred in their shares, so the columns do not line up row to
   row (`column-develop-tone-open.png` y 1652–1764). A 4-column grid with the second
   and third rows spanning two cells each would align them. Not a spacing change, so
   left for whoever owns the footer.
5. **Sidebar (`ContentView`).** Not touched. Its section rows and counts already sit on
   a consistent 12/18 pt rhythm in `window-1512x982-develop.png`; the only mismatch
   is the 10 pt `padding(.horizontal, 10)` at ContentView.swift:1361, which could read
   `Lumen.cardPaddingH` if the owner of that view agrees.
