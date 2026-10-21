import mtool, numpy as np, sys
from PIL import Image
root = sys.argv[1]
r = lambda s, n: mtool.read_f32(f'{root}/{s}/{n}.f32')
R, C = r('alg8559', 'R'), r('alg8559', 'C')
def stat(name, got, want):
    d = np.abs(got - want); print(f'{name:16s} max|Δ| {d.max():.4f}  mean {d.mean():.5f}  cov {got.mean():.4f}')
print('-- 8559 radial R vs colour range C (C partial px: %.1f%%)' % (100 * ((C > 0.02) & (C < 0.98)).mean()))
stat('add=max', r('alg8559', 'R_add_C'), np.maximum(R, C))
stat('sub vs min', r('alg8559', 'R_sub_C'), np.minimum(R, 1 - C))
stat('sub vs prod', r('alg8559', 'R_sub_C'), R * (1 - C))
stat('int=prod', r('alg8559', 'R_int_C'), R * C)
stat('int vs min', r('alg8559', 'R_int_C'), np.minimum(R, C))
stat('subC50 vs prod', r('alg8559', 'R_sub_C50'), R * (1 - 0.5 * C))
stat('R50 sub C prod', r('alg8559', 'R50_sub_C'), 0.5 * R * (1 - C))
stat('A3 R−C vs R∩¬C', r('alg8559', 'R_sub_C'), r('alg8559', 'R_int_Cinv'))
for op in ('add', 'sub', 'int'):
    stat(f'A4 {op} @0 vs R', r('alg8559', f'R_{op}_C0'), R)
stat('ref_X', r('alg8559', 'ref_X'), r('alg8559', 'R_sub_C'))
stat('ref_X_inv', r('alg8559', 'ref_X_inv'), 1 - r('alg8559', 'R_sub_C'))
stat('inv_ref_Xinv', r('alg8559', 'inv_ref_Xinv'), r('alg8559', 'R_sub_C'))
stat('ref_iX', r('alg8559', 'ref_iX'), 1 - r('alg8559', 'R_sub_C'))
stat('inv_R_sub_C', r('alg8559', 'inv_R_sub_C'), 1 - r('alg8559', 'R_sub_C'))
# where does min-subtract fail to remove anything: pixels with 0<C<1 and R<=1-C
RsC = r('alg8559', 'R_sub_C')
m = (C > 0.05) & (R > 0.05)
print('overlap px', m.sum(), ' frac where subtract removed nothing (|Δ|<.005):', ((np.abs(RsC - R) < .005) & m).sum() / max(m.sum(), 1))
L, U = r('alg983', 'L'), r('alg983', 'U')
print('-- 983 linear L vs luma U')
stat('L∩U prod', r('alg983', 'L_int_U'), L * U)
stat('U∩L == L∩U', r('alg983', 'U_int_L'), r('alg983', 'L_int_U'))
stat('L−U min', r('alg983', 'L_sub_U'), np.minimum(L, 1 - U))
stat('L−U prod', r('alg983', 'L_sub_U'), L * (1 - U))
