#!/usr/bin/env python3
"""
Convert Depth Anything V2 *Base* to Core ML, matching Apple's Small model I/O so
the app's CoreMLDepthProvider uses it unchanged.

Target I/O (mirrors apple/coreml-depth-anything-v2-small):
  input  "image": Color RGB image, 518 x 392 (W x H)
  output "depth": single-channel relative inverse depth (near = high)

We emit a plain MLMultiArray output (the Swift makeTexture() path min-max
normalizes it), which is the most robust route — no image-output range quirks.
ImageNet normalization is baked into the traced wrapper; the Core ML ImageType
feeds pixels in [0,1] via scale=1/255.
"""
import torch
import torch.nn.functional as F
import numpy as np
import coremltools as ct
from transformers import AutoModelForDepthEstimation

# coremltools has no upsample_bicubic2d op; the DepthAnything head upsamples
# bicubic. Apple's Small conversion used bilinear (its op histogram shows
# upsampleBilinear), so force bilinear here too — visually negligible for depth,
# and we re-refine with a joint-bilateral pass on-device anyway.
_orig_interpolate = F.interpolate
def _interpolate_bilinear(input, size=None, scale_factor=None, mode="nearest",
                          align_corners=None, **kwargs):
    if mode == "bicubic":
        mode = "bilinear"
    return _orig_interpolate(input, size=size, scale_factor=scale_factor,
                             mode=mode, align_corners=align_corners, **kwargs)
F.interpolate = _interpolate_bilinear

CKPT = "depth-anything/Depth-Anything-V2-Base-hf"
W, H = 518, 392          # matches Apple Small (multiples of 14: 37*14, 28*14)
OUT = "DepthAnythingV2BaseF16.mlpackage"

print(f"Loading {CKPT} ...")
model = AutoModelForDepthEstimation.from_pretrained(CKPT)
model.eval()


class DepthWrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
        self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

    def forward(self, x):
        # x in [0,1], shape (1,3,H,W) — Core ML ImageType (scale=1/255) feeds this.
        x = (x - self.mean) / self.std
        out = self.m(pixel_values=x).predicted_depth        # (1,H,W) inverse depth
        if out.dim() == 3:
            out = out.unsqueeze(1)                           # (1,1,H,W)
        # Per-frame min-max to [0,1] so float16 keeps precision; near = high.
        mn = out.amin(dim=[2, 3], keepdim=True)
        mx = out.amax(dim=[2, 3], keepdim=True)
        out = (out - mn) / (mx - mn + 1e-6)
        return out


wrapper = DepthWrapper(model).eval()
example = torch.rand(1, 3, H, W)
with torch.no_grad():
    ref = wrapper(example)
print("wrapper output shape:", tuple(ref.shape), "range:", float(ref.min()), float(ref.max()))

print("Tracing ...")
with torch.no_grad():
    traced = torch.jit.trace(wrapper, example)

print("Converting to Core ML ...")
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name="image", shape=(1, 3, H, W),
                         scale=1 / 255.0, bias=[0, 0, 0],
                         color_layout=ct.colorlayout.RGB)],
    outputs=[ct.TensorType(name="depth")],
    minimum_deployment_target=ct.target.iOS17,
    compute_precision=ct.precision.FLOAT16,
    compute_units=ct.ComputeUnit.ALL,
)

mlmodel.short_description = "Depth Anything V2 Base — monocular relative depth (Core ML, F16)."
mlmodel.author = "Original Paper: Lihe Yang et al. (Depth Anything V2)"
mlmodel.license = "Apache 2"
mlmodel.save(OUT)
print(f"Saved {OUT}")

# Report the realized I/O so we can confirm it matches the app's expectations.
spec = mlmodel.get_spec()
print("=== inputs ===")
for i in spec.description.input:
    print(" ", i.name, i.type.WhichOneof("Type"))
print("=== outputs ===")
for o in spec.description.output:
    print(" ", o.name, o.type.WhichOneof("Type"))
print("DONE")
