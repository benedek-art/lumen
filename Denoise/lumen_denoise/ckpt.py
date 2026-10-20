"""EMA weights + crash/pause-safe training checkpoints.

Layout in --out:  ckpt.pt = full training state (net, opt, sched, EMA, RNGs, step, best, extra)
                  last.pt / best.pt = PLAIN model state dicts (EMA weights when EMA is on), because
                  infer.py does Denoiser.from_state_dict(torch.load(path)) and knows nothing else.
All writes go to a temp file in the same dir, fsync, then os.replace: a crash / power loss / Ctrl-C
mid-save leaves the previous file intact (os.replace is atomic on APFS and ext4).
"""
import contextlib
import os
import random
import signal
import tempfile

import numpy as np
import torch


class EMA:
    """Polyak/EMA copy of the weights (BasicSR/NAFNet use decay 0.999). Averages away the last
    few hundred steps of SGD noise -> smoother val curve, typically +0.05-0.2 dB for free.
    warmup: decay_n = min(decay, (1+n)/(10+n)) (TF ExponentialMovingAverage num_updates), so the
    early EMA is not dominated by the random/zero init. Shadow is fp32 and keyed exactly like
    model.state_dict(), so it can be exported as plain weights. Buffers are copied, not averaged."""

    def __init__(self, model, decay=0.999, warmup=True):
        self.decay, self.warmup, self.n = float(decay), bool(warmup), 0
        self.shadow = {k: v.detach().clone().float() if v.is_floating_point() else v.detach().clone()
                       for k, v in model.state_dict().items()}
        self._params = {k for k, _ in model.named_parameters()}

    def cur_decay(self):
        return min(self.decay, (1 + self.n) / (10 + self.n)) if self.warmup else self.decay

    @torch.no_grad()
    def update(self, model):
        d = self.cur_decay()
        for k, v in model.state_dict().items():
            s = self.shadow[k]
            if k in self._params and s.is_floating_point():
                s.mul_(d).add_(v.detach().to(s.dtype), alpha=1 - d)
            else:
                s.copy_(v.detach())
        self.n += 1

    @torch.no_grad()
    def copy_to(self, model):
        for k, v in model.state_dict().items():
            v.copy_(self.shadow[k].to(v.dtype))

    @contextlib.contextmanager
    def swapped(self, model):
        """Temporarily run `model` with EMA weights (validation/export), then restore exactly."""
        backup = {k: v.detach().clone() for k, v in model.state_dict().items()}
        self.copy_to(model)
        try:
            yield model
        finally:
            with torch.no_grad():
                for k, v in model.state_dict().items():
                    v.copy_(backup[k])

    def weights(self):
        return {k: v.clone() for k, v in self.shadow.items()}

    def state_dict(self):
        return {"decay": self.decay, "warmup": self.warmup, "n": self.n, "shadow": self.shadow}

    def load_state_dict(self, sd):
        self.decay, self.warmup, self.n = float(sd["decay"]), bool(sd["warmup"]), int(sd["n"])
        for k, v in sd["shadow"].items():
            self.shadow[k] = v.detach().clone().to(self.shadow[k].device if k in self.shadow else v.device)


def _mps_ok():
    return hasattr(torch, "mps") and torch.backends.mps.is_available()


def rng_state():
    st = {"python": random.getstate(), "numpy": np.random.get_state(), "torch": torch.get_rng_state()}
    if _mps_ok():
        st["mps"] = torch.mps.get_rng_state()
    if torch.cuda.is_available():
        st["cuda"] = torch.cuda.get_rng_state_all()
    return st


def set_rng_state(st):
    random.setstate(st["python"]); np.random.set_state(st["numpy"])
    torch.set_rng_state(st["torch"].cpu())  # map_location may have moved the ByteTensor
    if "mps" in st and _mps_ok():
        torch.mps.set_rng_state(st["mps"].cpu())
    if "cuda" in st and torch.cuda.is_available():
        torch.cuda.set_rng_state_all([s.cpu() for s in st["cuda"]])


def atomic_save(obj, path):
    """torch.save to a temp file next to `path`, fsync, os.replace. Never leaves a partial `path`."""
    path = os.fspath(path)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".", suffix=".tmp", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "wb") as f:
            torch.save(obj, f); f.flush(); os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.remove(tmp)
        raise


def _plain(x):
    if isinstance(x, EMA):
        return x.weights()
    if isinstance(x, torch.nn.Module):
        return x.state_dict()
    if isinstance(x, dict) and "shadow" in x and "decay" in x:
        return x["shadow"]
    return x


def export_weights(path, net_or_ema_state):
    """Write a PLAIN state dict (what infer.py loads). Accepts a module, an EMA, an EMA state_dict
    or a state dict. Tensors go to CPU so the file loads anywhere without map_location."""
    sd = {k: v.detach().cpu().clone() for k, v in _plain(net_or_ema_state).items()}
    atomic_save(sd, path)


def save_ckpt(path, *, step, net, opt, sched, ema=None, best=None, extra=None):
    """Full training state. extra: anything picklable (args dict, adaptive ISO sampler state, ...)."""
    atomic_save({"step": int(step), "net": net.state_dict(), "opt": opt.state_dict(),
                 "sched": sched.state_dict() if sched is not None else None,
                 "ema": ema.state_dict() if ema is not None else None,
                 "best": best, "extra": extra, "rng": rng_state()}, path)


def load_ckpt(path, *, net, opt, sched, ema=None, map_location="cpu"):
    """Restore everything save_ckpt wrote, in place. Returns {step, best, extra}; resume at step+1."""
    ck = torch.load(path, map_location=map_location, weights_only=False)  # numpy RNG state needs pickle
    net.load_state_dict(ck["net"]); opt.load_state_dict(ck["opt"])
    if sched is not None and ck["sched"] is not None:
        sched.load_state_dict(ck["sched"])
    if ema is not None:
        if ck["ema"] is not None:
            ema.load_state_dict(ck["ema"])
        else:  # resuming an EMA-less run with EMA on: start the average from the current weights
            ema.shadow = EMA(net, ema.decay, ema.warmup).shadow
    set_rng_state(ck["rng"])
    return {"step": ck["step"], "best": ck["best"], "extra": ck["extra"]}


class StopFlag:
    """Set by a signal; the training loop polls `if stop: save_ckpt(...); break`."""

    def __init__(self):
        self.requested, self.signum, self._prev = False, None, {}

    def __bool__(self):
        return self.requested

    def restore(self):
        for s, h in self._prev.items():
            with contextlib.suppress(ValueError, OSError):
                signal.signal(s, h)
        self._prev = {}


def install_signal_handlers(callback=None, signals=("SIGTERM", "SIGINT", "SIGUSR1")):
    """SIGTERM (kill / app quit), SIGINT (Ctrl-C), SIGUSR1 (`kill -USR1 <pid>` = pause) only set a
    flag (+ optional cheap callback(signum)); the loop then checkpoints between steps, so a save is
    never interleaved with an optimizer step. A second SIGINT force-quits (KeyboardInterrupt).
    Must be called from the main thread; elsewhere it is a no-op and the flag simply never trips."""
    flag = StopFlag()

    def h(signum, frame):
        if flag.requested and signum == signal.SIGINT:
            raise KeyboardInterrupt
        flag.requested, flag.signum = True, signum
        if callback is not None:
            callback(signum)

    for name in signals:
        s = getattr(signal, name, None)
        if s is None:
            continue  # e.g. no SIGUSR1 on Windows
        try:
            flag._prev[s] = signal.signal(s, h)
        except ValueError:  # not main thread
            pass
    return flag
