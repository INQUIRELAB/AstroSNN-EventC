import numpy as np
import torch

from astrocyte import (
    DATASET_PRESETS,
    FAULT_FAMILIES,
    SEVERITY_TABLE,
    AstrocyteConfig,
    AstrocyteModule,
    AstrocyteNetwork,
    DefectivePixelCorrector,
    EventCGenerator,
    FiveBlockSNN,
    NCarsSNN,
    apply_event_c,
    apply_quantile_map,
    fit_astrocyte_calibration,
)


def test_event_c_all_families_and_severities():
    rng = np.random.default_rng(0)
    clip = rng.poisson(1.5, size=(8, 2, 32, 32)).astype(np.float32)
    gen = EventCGenerator(32, 32, rho=1.0, seed=42)
    for fam in FAULT_FAMILIES:
        assert len(SEVERITY_TABLE[fam]) == 5
        for sev in range(1, 6):
            out = gen.apply(clip, fam, severity=sev)
            assert out.shape == clip.shape
            assert out.dtype == clip.dtype
            assert np.all(out >= 0)
            assert np.allclose(out, np.rint(out))

    t_clip = torch.from_numpy(clip)
    t_out = apply_event_c(t_clip, "shot_noise", severity=3, dataset="cifar10_dvs", seed=7)
    assert isinstance(t_out, torch.Tensor)
    assert t_out.shape == t_clip.shape
    assert float(t_out.sum()) > float(t_clip.sum())


def test_event_c_nested_defect_masks():
    gen = EventCGenerator(64, 64, rho=1.0, seed=11)
    for sev in range(1, 5):
        m0_a, m1_a = gen._hot_mask(gen.parameter("hot_pixels", sev))
        m0_b, m1_b = gen._hot_mask(gen.parameter("hot_pixels", sev + 1))
        assert np.all((m0_a | m1_a) <= (m0_b | m1_b))

        dl_a = gen._dead_lines_mask(gen.parameter("dead_lines", sev))
        dl_b = gen._dead_lines_mask(gen.parameter("dead_lines", sev + 1))
        assert np.all(dl_a <= dl_b)

        dc_a = gen._dead_clusters_mask(gen.parameter("dead_clusters", sev))
        dc_b = gen._dead_clusters_mask(gen.parameter("dead_clusters", sev + 1))
        assert np.all(dc_a <= dc_b)


def test_dpc_repairs_hot_and_dead_pixels():
    torch.manual_seed(0)
    dpc = DefectivePixelCorrector(16, 16, dwell_frames=16)
    base = torch.full((16, 2, 16, 16), 2.0, dtype=torch.float32)
    base[:, 0, 5, 5] = 0.0
    base[:, 1, 5, 5] = 0.0
    base[:, 1, 10, 10] = 30.0

    for _ in range(2):
        repaired = dpc.process_clip(base)

    assert bool(dpc.flagged_mask[5, 5])
    assert bool(dpc.flagged_mask[10, 10])
    assert abs(float(repaired[-1, 0, 5, 5]) - 2.0) < 0.2
    assert abs(float(repaired[-1, 1, 10, 10]) - 2.0) < 0.2


def test_quantile_map_identity_and_shift_recovery():
    torch.manual_seed(1)
    clean = torch.randn(4, 16, 16)
    q_ref = torch.quantile(clean.reshape(4, -1), torch.linspace(0.0, 1.0, 101), dim=1).T
    zero = torch.zeros_like(q_ref)
    mapped_id = apply_quantile_map(clean, q_ref, zero)
    assert torch.allclose(mapped_id, clean, atol=1e-4)

    shifted = clean + 3.5
    shift = torch.full_like(q_ref, 3.5)
    recovered = apply_quantile_map(shifted, q_ref, shift)
    assert torch.allclose(recovered, clean, atol=1e-3)


def test_astrocyte_network_count_and_kalman_with_fixed_weights():
    torch.manual_seed(2)
    assert sum(p.numel() for p in FiveBlockSNN(num_classes=11).parameters()) == 1698926
    assert sum(p.numel() for p in FiveBlockSNN(num_classes=10).parameters()) == 1693796
    assert sum(p.numel() for p in FiveBlockSNN(num_classes=101).parameters()) == 2160626
    assert sum(p.numel() for p in NCarsSNN(num_classes=2).parameters()) == 9312084

    snn = FiveBlockSNN(num_classes=4, channels=(4, 8, 8, 8, 8), input_size=32, hidden_dim=16)
    weights_before = [p.detach().clone() for p in snn.parameters()]

    clean_clips = [torch.poisson(torch.full((4, 2, 32, 32), 1.0)) for _ in range(6)]
    gen = EventCGenerator(32, 32, rho=1.0, seed=9)
    fault_clips = [gen.apply(c, "shot_noise", severity=3) for c in clean_clips]

    cal = fit_astrocyte_calibration(snn, clean_clips, [fault_clips], ppca_components=3)

    cfg_count = AstrocyteConfig(mode="count", frames_per_clip=4, n0=16, clipped=False)
    mod_count = AstrocyteModule(cal.ref_quantiles, cfg_count, cal.shift_bounds, cal.recall_cal)
    net_count = AstrocyteNetwork(snn, mod_count, detector_threshold=0.5)

    plain_clean = snn(clean_clips[0])
    out_clean, info_clean = net_count.infer_clip(clean_clips[0], detector_score=0.05)
    assert not info_clean["learn"] and not info_clean["correct"]
    assert torch.allclose(out_clean, plain_clean)

    for fc in fault_clips:
        net_count.infer_clip(fc, detector_score=0.95)
    assert mod_count.learned_frames > 0

    cfg_kalman = AstrocyteConfig(
        mode="kalman",
        frames_per_clip=4,
        n0=16,
        clipped=True,
        use_previous_clip_summary=False,
        use_output_check=True,
    )
    mod_kalman = AstrocyteModule(cal.ref_quantiles, cfg_kalman, cal.shift_bounds, cal.recall_cal)
    net_kalman = AstrocyteNetwork(snn, mod_kalman, detector_threshold=0.5)
    for fc in fault_clips:
        _, info_k = net_kalman.infer_clip(fc, detector_score=0.95)
    assert mod_kalman.has_restarted
    assert info_k["correct"]

    for p_before, p_after in zip(weights_before, snn.parameters()):
        assert torch.equal(p_before, p_after)

    ncars = NCarsSNN(channels=(4, 4, 8, 8, 8, 8, 8, 8), input_size=48)
    logits_nc = ncars(torch.zeros((4, 2, 48, 48)))
    assert logits_nc.shape == (2,)
    assert set(DATASET_PRESETS.keys()) == {"dvs128_gesture", "cifar10_dvs", "n_caltech101", "n_cars"}
