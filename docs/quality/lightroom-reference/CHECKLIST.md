# Lightroom reference export

About 30 minutes, almost all of it Lightroom exporting while you do something else. These
exports are what turns "Lumen is as good as Lightroom" from a claim into a number.

## 1. Pick 6 RAWs (5 min)

Your own files, ideally A7 IV and GX85, one of each:

1. Portrait or skin in daylight
2. Backlit or high dynamic range (sun in frame, deep shadows)
3. Sky plus landscape or water (blues and greens)
4. Low light, high ISO (3200 or above)
5. Strongly saturated colour (pool, neon, sunset)
6. Something with fine texture and a neutral grey or white in it

Put them in one folder: `Lumen Reference/raw/`.

## 2. Import the presets (1 min)

Lightroom Classic: Develop module, Presets panel, click `+`, then Import Presets, and pick
`Lumen-Reference-Presets.zip` from this folder. You get a group called **Lumen Reference**
with 58 presets. Each one resets everything to neutral (Adobe Color, no sharpening, no NR,
no lens corrections) and moves exactly one control.

## 3. Set up the export once (2 min)

Select the 6 photos, apply **00 Baseline**, then File > Export:

- Export to: `Lumen Reference/lr/`
- Existing files: **Choose a new name for the exported file**
- File naming: Filename
- Format: JPEG, Quality 100, Colour space sRGB
- Resize: Long Edge, 2048 px, Don't Enlarge
- Output sharpening: **off**
- Metadata: **All Metadata** (this is how we tell the presets apart, so it matters)
- Watermark: off

Export.

## 4. Run the presets (about 15 min of clicking, mostly waiting)

For each preset in **Lumen Reference**, in order:

1. Keep all 6 photos selected in the filmstrip
2. Click the preset (Lightroom applies it to the selection only if Auto Sync is on, so
   turn **Auto Sync** on at the bottom of the right panel first)
3. Press **Cmd+Option+Shift+E** (Export with Previous)

Don't rename anything. The file names will collide and Lightroom adds `-2`, `-3`, and so on,
which is fine because every JPEG carries its own settings in the metadata.

When done, apply **00 Baseline** again so your photos are left neutral (or just reset them).

## 5. Hand it over

Upload the whole `Lumen Reference` folder (both `raw/` and `lr/`) to Google Drive and send me
the folder name. I'll pull it in, decode the RAWs through Lumen, and every audit agent gets
the matching Lightroom render to measure against.

If you use Lightroom (cloud) rather than Classic, the presets import the same way
(Edit > Presets > `...` > Import Presets); export each round as JPEG, 2048 px, sRGB,
with metadata included.
