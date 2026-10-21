"""Finding 2: overshoot / smoothness of MonotoneCubic (port)."""
import numpy as np, sys, os
sys.path.insert(0, os.path.dirname(__file__))
from curvelib import MonotoneCubic
rng = np.random.default_rng(1)
xs = np.linspace(0, 1, 200001)
def check(pts):
    f = MonotoneCubic(pts); y = f(xs)
    X = np.array(f.xs); Y = np.array(f.ys)
    worst = 0.0; nonmono_seg = 0
    for i in range(len(X) - 1):
        m = (xs >= X[i]) & (xs <= X[i + 1])
        lo, hi = min(Y[i], Y[i + 1]), max(Y[i], Y[i + 1])
        worst = max(worst, float(np.max(y[m] - hi)), float(np.max(lo - y[m])))
        dy = np.diff(y[m]); s = np.sign(Y[i + 1] - Y[i])
        if s != 0 and np.any(dy * s < -1e-15): nonmono_seg += 1
    # C1: numerical derivative jump at knots
    h = 1e-7; jumps = []
    for k in X[1:-1]:
        dl = (f(k) - f(k - h)) / h; dr = (f(k + h) - f(k)) / h
        jumps.append(abs(float(dr - dl)))
    return worst, nonmono_seg, max(jumps) if jumps else 0, float(y.min()), float(y.max())
print('fixed sets:')
for pts in ([[0,0],[.25,.15],[.75,.85],[1,1]], [[0,0],[.4,.1],[.6,.9],[1,1]], [[0,0],[.3,.8],[.35,.2],[1,1]],
            [[0,0],[.5,.5],[.52,.9],[1,1]], [[0,.1],[1,1]], [[0,0],[.2,.0],[.8,1],[1,1]]):
    print(pts, 'overshoot %.2e  nonmono-within-seg %d  max C1 jump %.2e  range [%.4f, %.4f]' % check(pts))
w = 0; nm = 0; cj = 0
for t in range(3000):
    n = rng.integers(3, 9)
    X = np.sort(rng.random(n)); X[0] = 0; X[-1] = 1
    X = np.unique(X)
    Y = rng.random(len(X)) if t % 2 else np.sort(rng.random(len(X)))
    a, b, c, _, _ = check(np.c_[X, Y].tolist())
    w = max(w, a); nm += b; cj = max(cj, c)
print('3000 random sets (half monotone, half not): max overshoot %.2e, segments non-monotone %d, max C1 jump %.2e' % (w, nm, cj))
# Lightroom-like natural cubic spline overshoot on the steep set, for comparison
from numpy.linalg import solve
def natural(X, Y, x):
    X = np.array(X, float); Y = np.array(Y, float); n = len(X); h = np.diff(X)
    A = np.zeros((n, n)); r = np.zeros(n); A[0, 0] = A[-1, -1] = 1
    for i in range(1, n - 1):
        A[i, i - 1] = h[i - 1]; A[i, i] = 2 * (h[i - 1] + h[i]); A[i, i + 1] = h[i]
        r[i] = 6 * ((Y[i + 1] - Y[i]) / h[i] - (Y[i] - Y[i - 1]) / h[i - 1])
    M = solve(A, r); i = np.clip(np.searchsorted(X, x) - 1, 0, n - 2); t = x - X[i]; hh = h[i]
    return (M[i] * (X[i + 1] - x) ** 3 / (6 * hh) + M[i + 1] * t ** 3 / (6 * hh)
            + (Y[i] / hh - M[i] * hh / 6) * (X[i + 1] - x) + (Y[i + 1] / hh - M[i + 1] * hh / 6) * t)
for pts in ([[0,0],[.4,.1],[.6,.9],[1,1]], [[0,0],[.3,.8],[.35,.2],[1,1]], [[0,0],[.25,.15],[.75,.85],[1,1]]):
    P = np.array(pts); y = natural(P[:, 0], P[:, 1], xs)
    print('natural cubic spline (LR-like)', pts, 'min %.3f max %.3f' % (y.min(), y.max()))
