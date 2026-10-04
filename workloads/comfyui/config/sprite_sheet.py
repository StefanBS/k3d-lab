# Cuts a sprite sheet with a transparent background into frames that line up. Image models
# don't draw an even grid, so cutting fixed cells (SplitImageToTileList) makes the sprite
# jump between frames, and lets parts of one cell's sprite spill into the next. This finds
# each sprite by the transparent gaps around it, in reading order, then shifts every frame
# so that it overlaps the first one best, on one canvas of the same size for all of them.
import logging

import numpy as np
import torch


def _runs(occupied, min_gap):
    """(start, end) of each run of True values, joining runs less than min_gap apart."""
    edges = np.flatnonzero(np.diff(np.concatenate(([0], occupied.astype(np.int8), [0]))))
    runs = []
    for start, end in zip(edges[::2], edges[1::2]):
        if runs and start - runs[-1][1] < min_gap:
            runs[-1] = (runs[-1][0], end)
        else:
            runs.append((start, end))
    return runs


def find_sprites(alpha, min_gap, min_size):
    """Bounding boxes (y0, y1, x0, x1) of the sprites in alpha, row by row, left to right."""
    boxes = []
    for y0, y1 in _runs(alpha.any(axis=1), min_gap):
        band = alpha[y0:y1]
        for x0, x1 in _runs(band.any(axis=0), min_gap):
            # A row whose sprites are not level can still have no empty line across the
            # whole sheet; within a column there is one.
            for sy0, sy1 in _runs(band[:, x0:x1].any(axis=1), min_gap):
                cols = np.flatnonzero(band[sy0:sy1, x0:x1].any(axis=0))
                box = (y0 + sy0, y0 + sy1, x0 + cols[0], x0 + cols[-1] + 1)
                if box[1] - box[0] >= min_size and box[3] - box[2] >= min_size:
                    boxes.append(box)
    return boxes


def _offset(reference, alpha):
    """The shift (dy, dx) that best lines alpha up with reference, by phase correlation."""
    cross = np.fft.fft2(reference) * np.conj(np.fft.fft2(alpha))
    peak = np.fft.ifft2(cross / (np.abs(cross) + 1e-9)).real
    h, w = peak.shape
    dy, dx = np.unravel_index(peak.argmax(), peak.shape)
    return (dy + h // 2) % h - h // 2, (dx + w // 2) % w - w // 2


def sheet_to_frames(rgba, threshold, min_gap, min_size, padding):
    """The sprites of one H x W x 4 sheet, aligned, as an N x h x w x 4 array."""
    boxes = find_sprites(rgba[..., 3] > threshold, min_gap, min_size)
    if not boxes:
        raise ValueError("no sprites found: the sheet needs a transparent background")
    h = max(y1 - y0 for y0, y1, _, _ in boxes) + 2 * padding
    w = max(x1 - x0 for _, _, x0, x1 in boxes) + 2 * padding

    def place(box, dy=0, dx=0):
        y0, y1, x0, x1 = box
        frame = np.zeros((h, w, 4), rgba.dtype)
        top = np.clip((h - (y1 - y0)) // 2 + dy, 0, h - (y1 - y0))
        left = np.clip((w - (x1 - x0)) // 2 + dx, 0, w - (x1 - x0))
        frame[top:top + y1 - y0, left:left + x1 - x0] = rgba[y0:y1, x0:x1]
        return frame

    reference = place(boxes[0])[..., 3]
    frames = [place(box, *_offset(reference, place(box)[..., 3])) for box in boxes]
    return np.stack(frames)


class SpriteSheetToFrames:
    CATEGORY = "image/sprite"
    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("frames",)
    FUNCTION = "split"
    DESCRIPTION = (
        "Finds each sprite on a sheet with a transparent background by the gaps around it, "
        "in reading order, and lines the frames up on one canvas, so an animation of them "
        "doesn't jump. Needs an image with alpha, such as BiRefNet's."
    )

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image": ("IMAGE",),
                "alpha_threshold": ("FLOAT", {"default": 0.5, "min": 0.0, "max": 1.0, "step": 0.05,
                    "tooltip": "Alpha above which a pixel belongs to a sprite."}),
                "min_gap": ("INT", {"default": 8, "min": 1, "max": 512,
                    "tooltip": "Transparent gap, in pixels, that separates two sprites. Smaller gaps are inside a sprite."}),
                "min_size": ("INT", {"default": 16, "min": 1, "max": 4096,
                    "tooltip": "Smallest width and height of a sprite, in pixels. Anything smaller is a speck and is dropped."}),
                "padding": ("INT", {"default": 8, "min": 0, "max": 512,
                    "tooltip": "Transparent margin around the largest sprite, in pixels."}),
            }
        }

    def split(self, image, alpha_threshold, min_gap, min_size, padding):
        if image.shape[-1] != 4:
            raise ValueError("the sheet has no alpha: remove its background first")
        frames = [
            sheet_to_frames(sheet.cpu().numpy(), alpha_threshold, min_gap, min_size, padding)
            for sheet in image
        ]
        if len({f.shape[1:] for f in frames}) > 1:
            raise ValueError("the sheets in the batch give frames of different sizes")
        out = np.concatenate(frames)
        logging.info("SpriteSheetToFrames: %d frames of %dx%d", len(out), out.shape[2], out.shape[1])
        return (torch.from_numpy(out),)


NODE_CLASS_MAPPINGS = {"SpriteSheetToFrames": SpriteSheetToFrames}
NODE_DISPLAY_NAME_MAPPINGS = {"SpriteSheetToFrames": "Sprite Sheet to Frames"}
