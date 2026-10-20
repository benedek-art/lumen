"""Render a (possibly denoised) normalized CFA through LibRaw, exactly like the original RAW."""
import numpy as np
import rawpy


def render(src_path, cfa_norm: np.ndarray | None = None, half=False) -> np.ndarray:
    """Return sRGB uint8 (H, W, 3). cfa_norm=None renders the original."""
    with rawpy.imread(str(src_path)) as r:
        if cfa_norm is not None:
            colors = r.raw_colors_visible
            bl = np.array(r.black_level_per_channel, np.float32)[colors]
            scale = r.white_level - np.mean(r.black_level_per_channel)
            dn = np.clip(cfa_norm * scale + bl, 0, r.white_level)
            r.raw_image_visible[:] = np.round(dn).astype(r.raw_image_visible.dtype)
        return r.postprocess(use_camera_wb=True, half_size=half, output_bps=8, user_flip=0,
                             no_auto_bright=True, bright=1.0,
                             demosaic_algorithm=rawpy.DemosaicAlgorithm.AHD)
