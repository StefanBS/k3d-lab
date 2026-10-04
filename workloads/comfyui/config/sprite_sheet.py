# Sprite sheet nodes for animations made from an image model's drawings.
#
# Sprite Sheet to Frames cuts a sheet with a transparent background into frames that line
# up. Image models don't draw an even grid, so cutting fixed cells (SplitImageToTileList)
# makes the sprite jump between frames, and lets parts of one cell's sprite spill into the
# next. It finds each sprite by the transparent gaps around it, in reading order, then
# shifts every frame so that it overlaps the first one best, on one canvas of the same size
# for all of them.
#
# Tread Frames animates a top-down tank from one drawing. Asked for two frames that differ
# only in the treads, an image model draws the whole tank again, a few pixels different,
# and the tank shakes. Like Battle City, it moves only the tread links instead: it finds
# each tread as the dark grey strip down a side of the sprite, measures how far apart its
# links are, and shifts the strip down by an equal part of that for each frame.
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


def find_treads(rgba, max_luma, max_saturation):
    """Boxes (y0, y1, x0, x1) of the treads: dark grey strips down the sides of the sprite."""
    rgb, opaque = rgba[..., :3], rgba[..., 3] > 0.5
    luma = rgb @ np.array([0.299, 0.587, 0.114], rgb.dtype)
    dark = opaque & (luma < max_luma) & (rgb.max(axis=-1) - rgb.min(axis=-1) < max_saturation)
    filled = np.flatnonzero(opaque.any(axis=0))
    if not len(filled):
        return []
    left, right = filled[0] + 0.3 * (filled[-1] - filled[0]), filled[0] + 0.7 * (filled[-1] - filled[0])
    # Outlines and shadows make some of every column dark; a tread makes most of its own.
    columns = dark.sum(axis=0) / max(1, opaque.any(axis=1).sum())
    boxes = []
    for x0, x1 in _runs(columns > 0.35, 1):
        if x1 - x0 < 4 or (x0 > left and x1 < right):
            continue
        # Its longest stretch of mostly dark rows, across the gaps between links. A hull
        # that covers part of the tread ends it.
        rows = _runs(dark[:, x0:x1].mean(axis=1) > 0.6, 12)
        if rows:
            y0, y1 = max(rows, key=lambda r: r[1] - r[0])
            if y1 - y0 >= 16:
                boxes.append((y0, y1, x0, x1))
    return boxes


def link_pitch(strip):
    """How far apart a tread's links are: the first peak of its brightness autocorrelation."""
    s = strip - strip.mean()
    ac = np.correlate(s, s, "full")[len(s) - 1:]
    if ac[0] <= 0:
        return None
    ac = ac / ac[0]
    for lag in range(3, len(ac) // 2):
        if ac[lag] > 0.2 and ac[lag - 1] < ac[lag] >= ac[lag + 1]:
            return lag
    return None


def tread_frames(rgba, frames, max_luma, max_saturation):
    """frames copies of one H x W x 4 sprite, its treads shifted on by 1/frames of a link each."""
    boxes = find_treads(rgba, max_luma, max_saturation)
    if not boxes:
        raise ValueError("no treads found: they need to be dark grey strips down the sides")
    treads = []
    for y0, y1, x0, x1 in boxes:
        pitch = link_pitch(rgba[y0:y1, x0:x1, :3].mean(axis=(1, 2)))
        if pitch is None:
            raise ValueError(f"no links found in the tread at x {x0}-{x1}, y {y0}-{y1}")
        treads.append(((y0, y1, x0, x1), pitch))
        logging.info("TreadFrames: tread at x %d-%d, y %d-%d, links %d px apart", x0, x1, y0, y1, pitch)
    out = np.repeat(rgba[None], frames, axis=0)
    for i in range(1, frames):
        for (y0, y1, x0, x1), pitch in treads:
            # The strip wraps around: the link pushed off the bottom comes back at the top.
            out[i, y0:y1, x0:x1] = np.roll(rgba[y0:y1, x0:x1], round(pitch * i / frames), axis=0)
    return out


class TreadFrames:
    CATEGORY = "image/sprite"
    RETURN_TYPES = ("IMAGE",)
    RETURN_NAMES = ("frames",)
    FUNCTION = "animate"
    DESCRIPTION = (
        "Animates a top-down tank from one sprite: every frame is the same sprite, with only "
        "the tread links moved on, so the hull doesn't shake. Finds the treads as the dark "
        "grey strips down its sides. Each sprite in the batch gives its own frames, in turn."
    )

    @classmethod
    def INPUT_TYPES(cls):
        return {
            "required": {
                "image": ("IMAGE",),
                "frames": ("INT", {"default": 2, "min": 2, "max": 16,
                    "tooltip": "Frames in the animation. The treads move on by a link over all of them."}),
                "max_luma": ("FLOAT", {"default": 0.35, "min": 0.0, "max": 1.0, "step": 0.01,
                    "tooltip": "Brightness below which a pixel can be tread. Raise it for lighter treads."}),
                "max_saturation": ("FLOAT", {"default": 0.12, "min": 0.0, "max": 1.0, "step": 0.01,
                    "tooltip": "Colourfulness below which a pixel can be tread: treads are grey, the hull isn't."}),
            }
        }

    def animate(self, image, frames, max_luma, max_saturation):
        if image.shape[-1] != 4:
            raise ValueError("the sprite has no alpha: remove its background first")
        out = np.concatenate([
            tread_frames(sprite.cpu().numpy(), frames, max_luma, max_saturation) for sprite in image
        ])
        return (torch.from_numpy(out),)

NODE_CLASS_MAPPINGS = {"SpriteSheetToFrames": SpriteSheetToFrames, "TreadFrames": TreadFrames}
NODE_DISPLAY_NAME_MAPPINGS = {
    "SpriteSheetToFrames": "Sprite Sheet to Frames",
    "TreadFrames": "Tread Frames",
}
