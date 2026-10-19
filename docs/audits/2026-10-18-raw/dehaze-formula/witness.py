#!/usr/bin/env python3
"""Independent scalar diagnostic, not a renderer/golden or calibration.
At commit 5d1ff3a: CPU DetailEngine.swift:399-483; GPU Kernels.swift:148-175;
RenderGraph.swift:1200-1224. Inputs intentionally expose omitted sky terms.
"""
import math
import struct
f32 = lambda x: struct.unpack('f', struct.pack('f', x))[0]
I, A, omega, distance = .8, 1., .95, .2
t = 1 - omega * I / A
base_floor = .55 + (.05 - .55) * distance
# Interior of a bright neutral flat patch: log2(I/.18)>2, gradient=0.
assert math.log2(I / .18) > 2
skyness = 1.
cpu_floor = base_floor + (.9 - base_floor) * skyness
positive_cpu = (I - A) / max(t, cpu_floor) + A
positive_gpu = (I - A) / max(t, base_floor) + A
negative_cpu = I + (A-I) * .9 * max(1-t, skyness)
negative_gpu = I + (A-I) * .9 * (1-t)
print(f'I={I} A={A} t={t:.12g} base_floor={base_floor:.12g} sky_floor={cpu_floor:.12g}')
for name, value in [('positive CPU',positive_cpu),('positive GPU',positive_gpu),('negative CPU',negative_cpu),('negative GPU',negative_gpu)]:
    print(f'{name}: analytic={value:.12g}; rounded_f32={f32(value):.12g}')
assert math.isclose(positive_cpu, 7/9)
assert math.isclose(positive_gpu, 5/9)
assert math.isclose(negative_cpu, .98)
assert math.isclose(negative_gpu, .9368)
assert positive_cpu > positive_gpu and negative_cpu > negative_gpu
# If sky evidence is zero both independently specified formulas coincide.
s = 0.
assert max(t, base_floor + (.9-base_floor)*s) == max(t, base_floor)
assert max(1-t, s) == 1-t
