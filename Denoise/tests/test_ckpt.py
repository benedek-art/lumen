import os
import random
import signal

import numpy as np
import pytest
import torch
import torch.nn as nn

from lumen_denoise import ckpt
from lumen_denoise.ckpt import EMA, export_weights, install_signal_handlers, load_ckpt, save_ckpt


def tiny():
    return nn.Sequential(nn.Conv2d(4, 8, 3, padding=1), nn.BatchNorm2d(8), nn.LeakyReLU(0.2), nn.Conv2d(8, 4, 3, padding=1))


def make(seed=0, iters=40):
    torch.manual_seed(seed)
    net = tiny()
    opt = torch.optim.AdamW(net.parameters(), 1e-2, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, 1e-2, total_steps=iters, pct_start=0.2)
    return net, opt, sched, EMA(net, 0.9)


def step(net, opt, sched, ema):
    """One step whose data depends on all three RNGs, like the real sampler (random/np/torch)."""
    s = random.random() * 0.5 + np.random.uniform(0.5, 1.0)
    x = torch.rand(2, 4, 8, 8) * s
    y = x + 0.1 * torch.randn_like(x)
    loss = (net(y) - x).abs().mean()
    opt.zero_grad(set_to_none=True); loss.backward()
    torch.nn.utils.clip_grad_norm_(net.parameters(), 1.0)
    opt.step(); sched.step(); ema.update(net)


def seed_all(s):
    random.seed(s); np.random.seed(s); torch.manual_seed(s)


def test_ema_math_and_warmup():
    net = nn.Linear(3, 2)
    e = EMA(net, decay=0.999, warmup=True)
    assert e.cur_decay() == pytest.approx(0.1)  # (1+0)/(10+0)
    e.n = 100000
    assert e.cur_decay() == pytest.approx(0.999)
    e.n = 20
    assert e.cur_decay() == pytest.approx(21 / 30)
    e2 = EMA(net, decay=0.9, warmup=False)
    old = {k: v.clone() for k, v in e2.shadow.items()}
    with torch.no_grad():
        for p in net.parameters():
            p.add_(1.0)
    e2.update(net)
    for k, v in net.state_dict().items():
        torch.testing.assert_close(e2.shadow[k], 0.9 * old[k] + 0.1 * v)
    assert e2.n == 1


def test_buffers_copied_not_averaged():
    net = tiny(); e = EMA(net, 0.5, warmup=False)
    net(torch.rand(2, 4, 8, 8))  # train mode -> running stats move
    e.update(net)
    bn = net[1]
    assert torch.equal(e.shadow["1.running_mean"], bn.running_mean)
    assert torch.equal(e.shadow["1.num_batches_tracked"], bn.num_batches_tracked)


def test_swapped_restores_exactly():
    net, opt, sched, e = make()
    for _ in range(5):
        step(net, opt, sched, e)
    before = {k: v.clone() for k, v in net.state_dict().items()}
    with e.swapped(net):
        for k, v in net.state_dict().items():
            assert torch.equal(v, e.shadow[k].to(v.dtype))
        assert any(not torch.equal(net.state_dict()[k], before[k]) for k in before)
    for k, v in net.state_dict().items():
        assert torch.equal(v, before[k])
    with pytest.raises(RuntimeError):  # restored even on exceptions inside validation
        with e.swapped(net):
            raise RuntimeError
    for k, v in net.state_dict().items():
        assert torch.equal(v, before[k])


def test_resume_bitwise(tmp_path):
    N = 10
    seed_all(1); a = make(iters=2 * N)
    for _ in range(2 * N):
        step(*a)
    nxt_a = (random.random(), np.random.rand(), torch.rand(3))

    seed_all(1); b = make(iters=2 * N)
    for _ in range(N):
        step(*b)
    p = tmp_path / "ckpt.pt"
    save_ckpt(p, step=N, net=b[0], opt=b[1], sched=b[2], ema=b[3], best=41.5, extra={"sampler": [1, 2], "args": {"nf": 48}})
    seed_all(999); torch.rand(100)  # clobber RNGs
    c = make(seed=7, iters=2 * N)  # fresh objects, different init
    info = load_ckpt(p, net=c[0], opt=c[1], sched=c[2], ema=c[3])
    assert info == {"step": N, "best": 41.5, "extra": {"sampler": [1, 2], "args": {"nf": 48}}}
    for _ in range(N):
        step(*c)
    nxt_c = (random.random(), np.random.rand(), torch.rand(3))

    for k, v in a[0].state_dict().items():
        assert torch.equal(v, c[0].state_dict()[k]), k
    for k, v in a[3].shadow.items():
        assert torch.equal(v, c[3].shadow[k]), k
    assert a[3].n == c[3].n == 2 * N
    sa, sc = a[1].state_dict(), c[1].state_dict()
    assert sa["param_groups"] == sc["param_groups"]
    for i in sa["state"]:
        for k in sa["state"][i]:
            assert torch.equal(sa["state"][i][k], sc["state"][i][k])
    assert a[2].get_last_lr() == c[2].get_last_lr()
    assert nxt_a[0] == nxt_c[0] and nxt_a[1] == nxt_c[1] and torch.equal(nxt_a[2], nxt_c[2])


def test_atomic_save_survives_interrupt(tmp_path, monkeypatch):
    net, opt, sched, e = make()
    p = tmp_path / "ckpt.pt"
    save_ckpt(p, step=3, net=net, opt=opt, sched=sched, ema=e)
    good = p.read_bytes()
    real = torch.save

    def boom(obj, f, *a, **k):
        f.write(b"partial garbage")
        raise KeyboardInterrupt  # Ctrl-C mid-write

    monkeypatch.setattr(ckpt.torch, "save", boom)
    with pytest.raises(KeyboardInterrupt):
        save_ckpt(p, step=4, net=net, opt=opt, sched=sched, ema=e)
    monkeypatch.setattr(ckpt.torch, "save", real)
    assert p.read_bytes() == good
    assert os.listdir(tmp_path) == ["ckpt.pt"]  # temp file cleaned up
    assert load_ckpt(p, net=net, opt=opt, sched=sched, ema=e)["step"] == 3


def test_export_plain_weights_loadable(tmp_path):
    from lumen_denoise.model import Denoiser
    net = Denoiser(nf=8, residual=True)
    e = EMA(net, 0.9)
    with torch.no_grad():
        for p in net.parameters():
            p.add_(0.01)
    e.update(net)
    for src in (net, e, e.state_dict()):
        export_weights(tmp_path / "best.pt", src)
        sd = torch.load(tmp_path / "best.pt")  # exactly how infer.py loads it
        m = Denoiser.from_state_dict(sd)
        ref = net.state_dict() if src is net else e.shadow
        for k, v in m.state_dict().items():
            assert torch.equal(v, ref[k].to(v.dtype))


def test_resume_without_ema_in_ckpt(tmp_path):
    net, opt, sched, e = make()
    save_ckpt(tmp_path / "c.pt", step=1, net=net, opt=opt, sched=sched)
    n2, o2, s2, e2 = make(seed=5)
    load_ckpt(tmp_path / "c.pt", net=n2, opt=o2, sched=s2, ema=e2)
    for k, v in n2.state_dict().items():
        assert torch.equal(e2.shadow[k].to(v.dtype), v)


@pytest.mark.skipif(not hasattr(signal, "SIGUSR1"), reason="posix only")
def test_signal_flag():
    seen = []
    flag = install_signal_handlers(seen.append)
    try:
        assert not flag
        os.kill(os.getpid(), signal.SIGUSR1)
        assert flag and flag.signum == signal.SIGUSR1 and seen == [signal.SIGUSR1]
        os.kill(os.getpid(), signal.SIGTERM)
        assert flag.signum == signal.SIGTERM
        with pytest.raises(KeyboardInterrupt):  # second Ctrl-C force-quits
            os.kill(os.getpid(), signal.SIGINT)
    finally:
        flag.restore()
    assert signal.getsignal(signal.SIGTERM) is not None
