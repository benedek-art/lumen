#!/usr/bin/env python3
"""Convert an ADE20K-trained semantic segmenter to the Core ML contract SkyModel reads.

    pip install torch torchvision transformers coremltools==8.*
    python3 convert_sky_model.py --hf <model-id> --out LumenSky.mlmodel
    shasum -a 256 LumenSky.mlmodel   # host it; SkyModel.install(from:sha256:)

A single-file .mlmodel (neural-network format), because SkyModel.install downloads
one file and compiles it; an .mlpackage is a directory.

Output contract (Sources/LumenPipeline/SkyModel.swift):
  * one image input, RGB, 512x512 (Core ML scales the picture to it);
  * one multi-array output [1, 150, H, W] of ADE20K class logits (sky = channel 2).

LICENCE CHECK BEFORE YOU SHIP ANYTHING. This script does not choose a model for you:
  * nvidia/segformer-*-finetuned-ade-*: NVIDIA Source Code License, NON-COMMERCIAL. Not
    shippable in a sold app.
  * Any ADE20K-trained weights inherit questions from the ADE20K dataset terms
    (research use). Get a decision on the weights you pick, in writing.
  * Safer routes: a sky model trained on a permissively licensed dataset (for example a
    U^2-Net / DeepLab trained on SkyFinder or a self-labelled set), or weights whose
    licence explicitly covers commercial redistribution.
The classical SkyDetector ships regardless; a model is an optional upgrade.
"""
import argparse

import coremltools as ct
import torch
from transformers import AutoModelForSemanticSegmentation


class Logits(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        mean = torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1)
        std = torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1)
        self.register_buffer("mean", mean)
        self.register_buffer("std", std)

    def forward(self, x):  # x: [1, 3, H, W] in 0..1 (Core ML scale=1/255 below)
        return self.model(pixel_values=(x - self.mean) / self.std).logits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hf", required=True, help="Hugging Face model id (ADE20K, 150 classes)")
    ap.add_argument("--size", type=int, default=512)
    ap.add_argument("--out", default="LumenSky.mlmodel")
    a = ap.parse_args()

    model = AutoModelForSemanticSegmentation.from_pretrained(a.hf).eval()
    labels = model.config.id2label
    assert labels.get(2, labels.get("2")) == "sky", f"class 2 is {labels.get(2)}, not sky"
    wrapped = Logits(model).eval()
    example = torch.rand(1, 3, a.size, a.size)
    traced = torch.jit.trace(wrapped, example)
    ml = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="logits")],
        convert_to="neuralnetwork",
        minimum_deployment_target=ct.target.macOS11,
    )
    ml.short_description = f"Sky segmentation for Lumen, converted from {a.hf}"
    ml.save(a.out)
    print("wrote", a.out)


if __name__ == "__main__":
    main()
