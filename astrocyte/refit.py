from __future__ import annotations

from dataclasses import dataclass
from typing import List, Optional, Sequence, Tuple

import torch
import torch.nn as nn

from .module import RecallCalibration, compute_channel_quantiles


@dataclass
class CalibrationBundle:
    ref_quantiles: List[torch.Tensor]
    shift_bounds: List[Tuple[torch.Tensor, torch.Tensor]]
    recall_cal: RecallCalibration


@torch.no_grad()
def _collect_layer_quantiles(snn: nn.Module, clips: Sequence[torch.Tensor]) -> List[torch.Tensor]:
    snn.eval()
    num_layers = len(snn.blocks)
    per_layer: List[List[torch.Tensor]] = [[] for _ in range(num_layers)]
    for clip in clips:
        snn.reset_state()
        clip_frames: List[List[torch.Tensor]] = [[] for _ in range(num_layers)]
        for t in range(clip.shape[0]):
            h = clip[t : t + 1]
            for l_idx, blk in enumerate(snn.blocks):
                cur = blk.current(h)[0]
                clip_frames[l_idx].append(compute_channel_quantiles(cur))
                h = blk.activate(cur.unsqueeze(0))
        for l_idx in range(num_layers):
            per_layer[l_idx].append(torch.stack(clip_frames[l_idx], dim=0))
    return [torch.stack(layer_list, dim=0) for layer_list in per_layer]


@torch.no_grad()
def fit_astrocyte_calibration(
    snn: nn.Module,
    clean_clips: Sequence[torch.Tensor],
    fault_streams: Sequence[Sequence[torch.Tensor]],
    ppca_components: int = 10,
    bound_scale: float = 1.5,
) -> CalibrationBundle:
    clean_q = _collect_layer_quantiles(snn, clean_clips)
    ref_quantiles = [q.mean(dim=(0, 1)) for q in clean_q]
    num_layers = len(ref_quantiles)

    clean_shifts = [clean_q[l] - ref_quantiles[l][None, None] for l in range(num_layers)]
    mu_layers = [s.mean(dim=(0, 1)) for s in clean_shifts]
    r_layers = [s.var(dim=(0, 1, 3), unbiased=False).clamp_min(1e-6) for s in clean_shifts]

    fault_stream_means: List[List[torch.Tensor]] = [[] for _ in range(num_layers)]
    all_fault_l0: List[torch.Tensor] = []
    for stream in fault_streams:
        fq = _collect_layer_quantiles(snn, stream)
        for l in range(num_layers):
            f_shift = fq[l] - ref_quantiles[l][None, None]
            fault_stream_means[l].append(f_shift.mean(dim=(0, 1)))
            if l == 0:
                all_fault_l0.append(f_shift.mean(dim=1))

    shift_bounds: List[Tuple[torch.Tensor, torch.Tensor]] = []
    p0_layers: List[torch.Tensor] = []
    for l in range(num_layers):
        if fault_stream_means[l]:
            stacked = torch.stack(fault_stream_means[l], dim=0)
            lo = bound_scale * torch.clamp(stacked.min(dim=0).values, max=0.0)
            hi = bound_scale * torch.clamp(stacked.max(dim=0).values, min=0.0)
            p0 = stacked.var(dim=(0, 2), unbiased=False).clamp_min(1e-4)
        else:
            lo = torch.full_like(ref_quantiles[l], -10.0)
            hi = torch.full_like(ref_quantiles[l], 10.0)
            p0 = r_layers[l].clone()
        shift_bounds.append((lo, hi))
        p0_layers.append(p0)

    clean_l0_summaries = clean_shifts[0].mean(dim=1)
    sd_0 = clean_l0_summaries.std(dim=0, unbiased=False).clamp_min(1e-6)
    z_clean = ((clean_l0_summaries - mu_layers[0][None]) / sd_0[None]).reshape(clean_l0_summaries.shape[0], -1)
    n_samples, m_dim = z_clean.shape
    k = min(int(ppca_components), max(1, n_samples - 1), m_dim)

    _, s_vals, vh = torch.linalg.svd(z_clean, full_matrices=False)
    eigs_all = (s_vals ** 2) / float(max(n_samples, 1))
    v_proj = vh[:k]
    eigenvalues = eigs_all[:k].clamp_min(1e-6)
    if len(eigs_all) > k and m_dim > k:
        sigma2 = float((eigs_all[k:].sum() / float(m_dim - k)).clamp_min(1e-6).item())
    else:
        sigma2 = float(eigenvalues[-1].clamp_min(1e-6).item())

    def ppca_dist(summary: torch.Tensor, base: torch.Tensor) -> float:
        z = ((summary - base) / sd_0).reshape(-1)
        xi = torch.mv(v_proj, z)
        sub = torch.sum((xi * xi) / eigenvalues)
        res = torch.clamp(torch.dot(z, z) - torch.dot(xi, xi), min=0.0) / sigma2
        return float(((sub + res) / float(m_dim)).item())

    clean_dists = torch.tensor([ppca_dist(s, mu_layers[0]) for s in clean_l0_summaries], dtype=torch.float32)
    tau_0 = float(torch.quantile(clean_dists, 0.99).item()) if len(clean_dists) > 0 else 10.0

    margin = 0.0
    if all_fault_l0 and fault_stream_means[0]:
        diffs: List[float] = []
        for s_idx, f_clips in enumerate(all_fault_l0):
            stored = fault_stream_means[0][s_idx]
            for clip_sum in f_clips:
                diffs.append(ppca_dist(clip_sum, stored) - ppca_dist(clip_sum, mu_layers[0]))
        if diffs:
            margin = max(0.0, float(torch.quantile(torch.tensor(diffs, dtype=torch.float32), 0.95).item()))

    channel_var_0 = clean_l0_summaries.var(dim=(0, 2), unbiased=False).clamp_min(1e-6)
    recall_cal = RecallCalibration(
        mu_layers=mu_layers,
        p0_layers=p0_layers,
        r_layers=r_layers,
        tau_0=tau_0,
        margin=margin,
        sd_0=sd_0,
        v_proj=v_proj,
        eigenvalues=eigenvalues,
        sigma2=sigma2,
        channel_var_0=channel_var_0,
    )
    return CalibrationBundle(ref_quantiles=ref_quantiles, shift_bounds=shift_bounds, recall_cal=recall_cal)
