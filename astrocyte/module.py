from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence, Tuple

import math
import torch
import torch.nn as nn


QUANTILE_LEVELS = torch.linspace(0.0, 1.0, 101, dtype=torch.float32)


@dataclass
class AstrocyteConfig:
    mode: str = "kalman"
    frames_per_clip: int = 16
    n0: int = 64
    eta_fast: float = 6.91e-4
    eta_slow: float = 2.19e-4
    clipped: bool = False
    use_previous_clip_summary: bool = False
    use_output_check: bool = True
    distance_metric: str = "ppca"
    ema_half_life: float = 2.0


DATASET_PRESETS: Dict[str, AstrocyteConfig] = {
    "dvs128_gesture": AstrocyteConfig(
        mode="kalman",
        frames_per_clip=16,
        n0=64,
        eta_fast=6.91e-4,
        eta_slow=2.19e-4,
        clipped=True,
        use_previous_clip_summary=True,
        use_output_check=False,
        distance_metric="ppca",
    ),
    "cifar10_dvs": AstrocyteConfig(
        mode="kalman",
        frames_per_clip=16,
        n0=64,
        eta_fast=6.91e-4,
        eta_slow=2.19e-4,
        clipped=True,
        use_previous_clip_summary=False,
        use_output_check=True,
        distance_metric="ppca",
    ),
    "n_caltech101": AstrocyteConfig(
        mode="kalman",
        frames_per_clip=16,
        n0=64,
        eta_fast=9.77e-4,
        eta_slow=9.77e-4,
        clipped=True,
        use_previous_clip_summary=False,
        use_output_check=True,
        distance_metric="diag",
    ),
    "n_cars": AstrocyteConfig(
        mode="count",
        frames_per_clip=10,
        n0=40,
        eta_fast=6.91e-4,
        eta_slow=2.19e-4,
        clipped=True,
        use_previous_clip_summary=False,
        use_output_check=False,
        distance_metric="none",
    ),
}


class CausalEmaGate:
    def __init__(self, threshold: float = 0.5, half_life: float = 2.0) -> None:
        self.threshold = float(threshold)
        self.beta = 1.0 - math.pow(2.0, -1.0 / float(half_life))
        self.p_bar: Optional[float] = None

    def reset(self) -> None:
        self.p_bar = None

    def step(self, raw_score: float) -> Tuple[bool, float]:
        score = float(raw_score)
        if self.p_bar is None:
            flag = False
            self.p_bar = score
        else:
            flag = self.p_bar > self.threshold
            self.p_bar = self.p_bar + self.beta * (score - self.p_bar)
        return flag, self.p_bar


def compute_channel_quantiles(current_chw: torch.Tensor) -> torch.Tensor:
    flat = current_chw.reshape(current_chw.shape[0], -1).to(torch.float32)
    levels = QUANTILE_LEVELS.to(device=flat.device, dtype=flat.dtype)
    return torch.quantile(flat, levels, dim=1).transpose(0, 1).contiguous()


def apply_quantile_map(
    current_chw: torch.Tensor,
    ref_quantiles_ck: torch.Tensor,
    shift_ck: torch.Tensor,
) -> torch.Tensor:
    c, h, w = current_chw.shape
    dtype = current_chw.dtype
    x = current_chw.reshape(c, -1).to(torch.float32)
    q_ref = ref_quantiles_ck.to(device=x.device, dtype=torch.float32)
    raw_t = q_ref + shift_ck.to(device=x.device, dtype=torch.float32)
    t_q = torch.cummax(raw_t, dim=1).values

    k_max = t_q.shape[1] - 1
    out = torch.empty_like(x)
    t0 = t_q[:, 0:1]
    tk = t_q[:, -1:]
    q0 = q_ref[:, 0:1]
    qk = q_ref[:, -1:]

    below = x < t0
    above = x > tk

    idx_left = torch.searchsorted(t_q, x, right=False)
    idx_right = torch.searchsorted(t_q, x, right=True)

    exact = idx_right > idx_left
    mid_level = 0.5 * (idx_left.to(torch.float32) + (idx_right - 1).to(torch.float32))
    lo_mid = torch.floor(mid_level).clamp(0, k_max).long()
    hi_mid = torch.ceil(mid_level).clamp(0, k_max).long()
    frac_mid = mid_level - lo_mid.to(torch.float32)
    q_mid_lo = torch.gather(q_ref, 1, lo_mid)
    q_mid_hi = torch.gather(q_ref, 1, hi_mid)
    y_exact = q_mid_lo + frac_mid * (q_mid_hi - q_mid_lo)

    k0 = (idx_left - 1).clamp(0, k_max - 1)
    k1 = k0 + 1
    t_lo = torch.gather(t_q, 1, k0)
    t_hi = torch.gather(t_q, 1, k1)
    q_lo = torch.gather(q_ref, 1, k0)
    q_hi = torch.gather(q_ref, 1, k1)
    denom = torch.where((t_hi - t_lo) > 0.0, t_hi - t_lo, torch.ones_like(t_hi))
    y_interp = q_lo + ((x - t_lo) * (q_hi - q_lo)) / denom

    y_mid = torch.where(exact, y_exact, y_interp)
    out = torch.where(below, x + q0 - t0, torch.where(above, x + qk - tk, y_mid))
    return out.reshape(c, h, w).to(dtype=dtype)


@dataclass
class RecallCalibration:
    mu_layers: List[torch.Tensor]
    p0_layers: List[torch.Tensor]
    r_layers: List[torch.Tensor]
    tau_0: float = 10.0
    margin: float = 0.0
    sd_0: Optional[torch.Tensor] = None
    v_proj: Optional[torch.Tensor] = None
    eigenvalues: Optional[torch.Tensor] = None
    sigma2: float = 1.0
    channel_var_0: Optional[torch.Tensor] = None


class AstrocyteModule:
    def __init__(
        self,
        ref_quantiles: Sequence[torch.Tensor],
        config: AstrocyteConfig,
        shift_bounds: Optional[Sequence[Tuple[torch.Tensor, torch.Tensor]]] = None,
        recall_cal: Optional[RecallCalibration] = None,
        device: torch.device | str = "cpu",
    ) -> None:
        self.device = torch.device(device)
        self.config = config
        self.ref_quantiles = [q.to(device=self.device, dtype=torch.float32).clone() for q in ref_quantiles]
        self.num_layers = len(self.ref_quantiles)
        self.shift_bounds = (
            [(lo.to(self.device, torch.float32), hi.to(self.device, torch.float32)) for lo, hi in shift_bounds]
            if shift_bounds is not None
            else None
        )
        self.recall_cal = recall_cal
        self.reset()

    def reset(self) -> None:
        self.shifts = [torch.zeros_like(q) for q in self.ref_quantiles]
        self.learned_frames = 0
        self.has_restarted = False
        self.prev_summary: Optional[torch.Tensor] = None
        if self.recall_cal is not None:
            self.p_var = [p0.to(self.device, torch.float32).clone() for p0 in self.recall_cal.p0_layers]
        else:
            self.p_var = [torch.ones(q.shape[0], device=self.device, dtype=torch.float32) for q in self.ref_quantiles]

    def _distance(self, summary_ck: torch.Tensor, base_ck: torch.Tensor) -> float:
        cal = self.recall_cal
        if cal is None:
            return float(((summary_ck - base_ck) ** 2).mean().item())
        if self.config.distance_metric == "diag":
            r0 = cal.channel_var_0.to(device=self.device, dtype=torch.float32).clamp_min(1e-8)
            per_ch = ((summary_ck - base_ck) ** 2).mean(dim=1) / r0
            return float(per_ch.mean().item())
        sd = cal.sd_0.to(device=self.device, dtype=torch.float32).clamp_min(1e-6)
        z = ((summary_ck - base_ck) / sd).reshape(-1)
        m_dim = float(z.numel())
        if cal.v_proj is None or cal.eigenvalues is None:
            return float((z * z).mean().item())
        v = cal.v_proj.to(device=self.device, dtype=torch.float32)
        eig = cal.eigenvalues.to(device=self.device, dtype=torch.float32).clamp_min(1e-8)
        xi = torch.mv(v, z)
        subspace = torch.sum((xi * xi) / eig)
        resid = torch.clamp(torch.dot(z, z) - torch.dot(xi, xi), min=0.0) / max(float(cal.sigma2), 1e-8)
        return float(((subspace + resid) / m_dim).item())

    def decide_clip(
        self,
        detector_flag: bool,
        layer0_summary: Optional[torch.Tensor] = None,
    ) -> Tuple[bool, bool, bool]:
        if self.config.mode == "count":
            return bool(detector_flag), bool(detector_flag), False

        summary = self.prev_summary if self.config.use_previous_clip_summary else layer0_summary
        if summary is None:
            if detector_flag:
                return True, False, False
            return False, False, False

        cal = self.recall_cal
        mu_0 = cal.mu_layers[0].to(self.device, torch.float32) if cal is not None else torch.zeros_like(summary)
        s0 = self._distance(summary, mu_0)
        s_d = self._distance(summary, self.shifts[0])
        margin = cal.margin if cal is not None else 0.0
        tau_0 = cal.tau_0 if cal is not None else 10.0

        recall = self.has_restarted and (s_d < s0 + (margin if detector_flag else 0.0))
        new_fault = (not recall) and ((s0 > tau_0) or (detector_flag and not self.has_restarted))

        if new_fault:
            self.restart()
            return True, True, True
        if recall:
            return True, True, False
        if detector_flag:
            return True, False, False
        return False, False, False

    def restart(self) -> None:
        if self.recall_cal is not None:
            for l in range(self.num_layers):
                self.shifts[l].copy_(self.recall_cal.mu_layers[l].to(self.device, torch.float32))
                self.p_var[l].copy_(self.recall_cal.p0_layers[l].to(self.device, torch.float32))
        else:
            for l in range(self.num_layers):
                self.shifts[l].zero_()
                self.p_var[l].fill_(1.0)
        self.learned_frames = 0
        self.has_restarted = True

    @torch.no_grad()
    def step_layer(
        self,
        layer_idx: int,
        current_chw: torch.Tensor,
        learn: bool,
        correct: bool,
    ) -> Tuple[torch.Tensor, Optional[torch.Tensor]]:
        obs_shift = None
        if learn or layer_idx == 0:
            q_frame = compute_channel_quantiles(current_chw.to(self.device))
            obs_shift = q_frame - self.ref_quantiles[layer_idx]

        if learn and obs_shift is not None:
            err = obs_shift - self.shifts[layer_idx]
            if self.config.mode == "count":
                g_val = 1.0 / float(self.learned_frames + self.config.n0 + 1)
                g = torch.full((err.shape[0], 1), g_val, device=self.device, dtype=torch.float32)
            else:
                r = (
                    self.recall_cal.r_layers[layer_idx].to(self.device, torch.float32)
                    if self.recall_cal is not None
                    else torch.full((err.shape[0],), float(self.config.n0), device=self.device)
                )
                p = self.p_var[layer_idx]
                g_vec = p / (p + r).clamp_min(1e-12)
                self.p_var[layer_idx] = (1.0 - g_vec) * p
                g = g_vec.unsqueeze(1)

            a_fast = torch.clamp(g, min=self.config.eta_fast)
            a_slow = torch.clamp(g, min=self.config.eta_slow)
            step = torch.where(err > 0.0, a_fast, a_slow)
            updated = self.shifts[layer_idx] + step * err
            if self.config.clipped and self.shift_bounds is not None:
                lo, hi = self.shift_bounds[layer_idx]
                updated = torch.clamp(updated, min=lo, max=hi)
            self.shifts[layer_idx] = updated

        out = current_chw
        if correct:
            out = apply_quantile_map(current_chw, self.ref_quantiles[layer_idx], self.shifts[layer_idx])
        return out, obs_shift

    def finish_frame(self, learned: bool) -> None:
        if learned:
            self.learned_frames += 1

    def update_prev_summary(self, summary_0: torch.Tensor) -> None:
        self.prev_summary = summary_0.detach().to(self.device, torch.float32).clone()


class AstrocyteNetwork:
    def __init__(
        self,
        snn: nn.Module,
        module: AstrocyteModule,
        gate: Optional[CausalEmaGate] = None,
        detector_threshold: float = 0.5,
    ) -> None:
        self.snn = snn
        self.module = module
        self.gate = gate if gate is not None else CausalEmaGate(threshold=detector_threshold, half_life=module.config.ema_half_life)
        self.detector_threshold = float(detector_threshold)
        self.snn.eval()
        for p in self.snn.parameters():
            p.requires_grad_(False)

    def reset(self) -> None:
        self.module.reset()
        self.gate.reset()

    @torch.no_grad()
    def _layer0_summary(self, clip_t2hw: torch.Tensor) -> torch.Tensor:
        blk0 = self.snn.blocks[0]
        shifts = []
        for t in range(clip_t2hw.shape[0]):
            cur0 = blk0.current(clip_t2hw[t : t + 1])[0]
            q0 = compute_channel_quantiles(cur0.to(self.module.device))
            shifts.append(q0 - self.module.ref_quantiles[0])
        return torch.stack(shifts, dim=0).mean(dim=0)

    @torch.no_grad()
    def _forward_plain(self, clip_t2hw: torch.Tensor) -> torch.Tensor:
        return self.snn(clip_t2hw)

    @torch.no_grad()
    def infer_clip(
        self,
        clip_t2hw: torch.Tensor,
        detector_score: float,
    ) -> Tuple[torch.Tensor, Dict[str, object]]:
        flag, p_bar = self.gate.step(detector_score)
        cfg = self.module.config

        layer0_summary = None
        if cfg.mode == "kalman" and not cfg.use_previous_clip_summary:
            layer0_summary = self._layer0_summary(clip_t2hw)

        learn, correct, restarted = self.module.decide_clip(flag, layer0_summary=layer0_summary)

        self.snn.reset_state()
        logits_acc = None
        obs0_frames = []
        for t in range(clip_t2hw.shape[0]):
            h = clip_t2hw[t : t + 1]
            for l_idx, blk in enumerate(self.snn.blocks):
                cur = blk.current(h)[0]
                cur_out, obs = self.module.step_layer(l_idx, cur, learn=learn, correct=correct)
                if l_idx == 0 and obs is not None:
                    obs0_frames.append(obs)
                h = blk.activate(cur_out.unsqueeze(0))
            self.module.finish_frame(learn)
            out = self.snn.classify_features(h)[0]
            logits_acc = out if logits_acc is None else logits_acc + out

        logits = logits_acc / float(clip_t2hw.shape[0])
        if cfg.mode == "kalman" and cfg.use_previous_clip_summary and obs0_frames:
            self.module.update_prev_summary(torch.stack(obs0_frames, dim=0).mean(dim=0))

        if cfg.use_output_check and correct and float(detector_score) <= self.detector_threshold:
            logits = self._forward_plain(clip_t2hw)

        return logits, {
            "flag": flag,
            "p_bar": p_bar,
            "learn": learn,
            "correct": correct,
            "restarted": restarted,
        }
