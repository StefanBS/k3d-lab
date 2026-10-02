# Fails a job at the first NaN rather than saving a black or noise image: in the
# denoiser's output at any step, or in any VAE encode or decode. On ROCm, ComfyUI's
# dynamic VRAM has corrupted the VAE under memory pressure (docs/benchmarks/qwen-image-2.1.md);
# --reserve-vram prevents it, and this makes any recurrence fail loudly.
import logging

import torch

import comfy.model_base
import comfy.sd


class NaNDetected(RuntimeError):
    pass


def _check(where, out):
    if torch.is_tensor(out) and bool(torch.isnan(out).any()):
        logging.error("NANGUARD NaN in %s", where)
        raise NaNDetected(f"NaN in {where}")
    return out


_apply_model = comfy.model_base.BaseModel.apply_model


def apply_model(self, *args, **kwargs):
    return _check("denoiser output", _apply_model(self, *args, **kwargs))


comfy.model_base.BaseModel.apply_model = apply_model

for _name in ("encode", "decode"):
    def _wrap(self, *args, _orig=getattr(comfy.sd.VAE, _name), _where=f"VAE {_name}", **kwargs):
        return _check(_where, _orig(self, *args, **kwargs))
    setattr(comfy.sd.VAE, _name, _wrap)

logging.info("NANGUARD installed")
NODE_CLASS_MAPPINGS = {}
