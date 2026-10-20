# Single-pass DNG write (opt-in)

Default (two-pass), `lumen_denoise/dng.py`:

1. `Adobe DNG Converter -c -u -p0` on the source raw (uncompressed DNG). This only depends on
   the source, so `dng.start(src)` launches it in the background while the GPU denoises.
2. `_patch_cfa` overwrites the CFA pixels in place and writes a new RawDataUniqueID (50781).
3. `Adobe DNG Converter -c -p0` on the patched DNG: lossless recompression, recomputed
   NewRawImageDigest (51111), previews rendered from the denoised data.

Single-pass (`LUMEN_DNG_SINGLE_PASS=1` or `write_cfa_dng(..., single_pass=True)`) skips step 3.
That needs the raw digest to stay valid, because Lightroom reports a DNG whose digest does not
match its pixels as damaged.

## Digest handling

- NewRawImageDigest (51111, DNG 1.4+) is an MD5 of the decoded pixels. The spec text describes a
  plain row-scan MD5, but the DNG SDK computes an MD5 per 256x256 tile and then an MD5 over those
  tile digests. Neither can be confirmed here without the SDK or Adobe's files.
- RawImageDigest (50972, legacy) is checked the same way.
- So nothing is assumed. Before patching, `_patch_cfa` computes each candidate algorithm on the
  untouched pass-1 pixels and compares it with the value Adobe stored:
  - **If a candidate matches**, the algorithm is proven for that file, and the digest is
    recomputed on the patched pixels and written in place.
  - **If none matches**, the tag is neutralized: its 2-byte tag id is renamed in place to an
    unused private id between its IFD neighbours, so the IFD stays sorted. A DNG with no digest
    tag is valid; readers just skip verification. The 16 bytes stay in the file and nothing is
    moved.
  - `_patch_cfa` returns `{tag: "recomputed" | "neutralized"}`, which tells you which branch ran.
- A new RawDataUniqueID is written either way, so Lightroom does not reuse the source's caches.

## Trade-offs

| | two-pass | single-pass |
|---|---|---|
| Converter runs | 2 (~3 s total) | 1, overlapped with inference |
| Expected saving | — | ~1.5 s per file (the whole pass 2) |
| File size | lossless-compressed | uncompressed (~2x larger, ~65-70 MB for 33 MP) |
| Embedded preview/thumbnail | rendered from denoised data | **stale**: shows the noisy original |
| Digest | Adobe-computed | recomputed if proven, else removed |

## To check on the Mac (not possible on the cloud box)

1. Run `python -m pytest tests/test_dng.py` with `data/samples` and the converter present. The
   identity round trip runs in both modes.
2. On one ARW and one RW2, call `dng._patch_cfa(mid, cfa, orig, black, fix_digests=True)` on a
   pass-1 file. Note whether 51111 is `recomputed` or `neutralized`. `recomputed` means our SDK
   algorithm reproduces Adobe's value exactly.
3. Import single-pass and two-pass outputs of the same file into Lightroom Classic:
   - both open with no "file appears to be damaged" warning, including after Library >
     Validate DNG Files;
   - in Develop with identical settings, the two renders look the same (difference blend in
     Photoshop is black);
   - the Library grid thumbnail of the single-pass file is the stale noisy preview until Lightroom
     renders its own (expected);
   - record both file sizes.
4. Time 10 files with and without `LUMEN_DNG_SINGLE_PASS=1`, and compare the `total_s` values.
5. If every point passes, single-pass can become the default for culling. Otherwise, keep
   two-pass.
