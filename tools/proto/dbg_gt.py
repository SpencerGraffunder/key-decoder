"""debug probe: where do GT cut centers / shoulder / tip land in blob bin space?"""
import numpy as np, cv2, synth, pipeline

def probe(sysid, cond, seed):
    captured = []
    orig = synth._transform
    orig_render = synth.render_scene
    holder = {}
    def spy(pts, M):
        out = orig(pts, M)
        captured.append((np.asarray(M, float).copy(), np.asarray(out).copy()))
        return out
    def render_spy(rng, sysd_, digits_, depths_, condition):
        scene, cq = orig_render(rng, sysd_, digits_, depths_, condition)
        holder["card_quad"] = np.asarray(cq).copy()
        return scene, cq
    synth._transform = spy
    synth.render_scene = render_spy
    try:
        s = synth.make_sample(sysid, cond, seed)
    finally:
        synth._transform = orig
        synth.render_scene = orig_render
    card_quad = holder["card_quad"]
    lay = dict(synth.LAST_LAYOUT)
    # Hp = last 4x2 transform whose output matches s.quad
    Hp = None
    for M, out in reversed(captured):
        if out.shape == (4, 2) and np.allclose(out, s.quad):
            Hp = M
            break
    assert Hp is not None, "no Hp match"
    assert np.abs(orig(card_quad, Hp) - s.quad).max() < 1e-6
    q = pipeline.order_quad(s.quad)
    dst = np.float32([[0, 0], [pipeline.W_OUT, 0], [pipeline.W_OUT, pipeline.H_OUT],
                      [0, pipeline.H_OUT]])
    Hc = cv2.getPerspectiveTransform(q.astype(np.float32), dst)

    def sc2xy(x, y):
        p = Hp @ np.array([x, y, 1.0])
        p = p[:2] / p[2]
        r = Hc @ np.array([p[0], p[1], 1.0])
        return r[:2] / r[2]

    r = pipeline.decode(s.photo, s.quad, s.sysd)
    g = r["debug"]["geom"]
    def bin_of(xy):
        du = xy - g["c"]
        return float(np.round(du @ g["e1"]) - g["u_off"])

    shoulder = sc2xy(lay["shoulder_x"], lay["centerline"])
    tip = sc2xy(lay["tip_x"], lay["centerline"])
    cts = [sc2xy(x, lay["centerline"]) for x in lay["centers"]]
    print(f"{sysid} {cond} seed{seed}: flip={lay['flip']} pred={r['code']} "
          f"truth={'-'.join(map(str,s.digits))}")
    b_sh, b_tip = bin_of(shoulder), bin_of(tip)
    b_cts = [bin_of(p) for p in cts]
    print("  blob bins", g["bins"][0], g["bins"][-1],
          "  GT shoulder bin", round(b_sh, 1), " GT tip bin", round(b_tip, 1),
          " blob ends off GT by", round(b_sh - g["bins"][0], 1),
          "and", round(g["bins"][-1] - b_tip, 1))
    print("  GT cut bins:", [round(b, 1) for b in b_cts])
    print("  GT spac px", round(lay["spac"] / 1, 1), "->",
          [round(b_cts[i+1]-b_cts[i], 1) for i in range(len(b_cts)-1)])
    for t in r["dir_fits"]:
        print("   dir_fits", t)
    if r["cuts"]:
        print("   picked centers", [round(c["u"], 1) for c in r["cuts"]])
        print("   GT-err", [round(c["u"] - b, 1) for c, b in zip(r["cuts"], b_cts)])

if __name__ == "__main__":
    import sys
    args = sys.argv[1:]
    for a in args or [("sc1", "headless", 1)]:
        probe(*a) if isinstance(a, tuple) else probe(*a)
