from __future__ import annotations

import torch
import torch.nn.functional as F


class DefectivePixelCorrector:
    def __init__(
        self,
        height: int,
        width: int,
        alpha: float = 1.0 / 512.0,
        dead_ratio: float = 0.15,
        dead_release: float = 0.30,
        hot_ratio: float = 3.0,
        hot_release: float = 1.5,
        dwell_frames: int = 16,
        activity_floor: float = 0.05,
        jacobi_steps: int = 20,
        device: torch.device | str = "cpu",
    ) -> None:
        self.height = int(height)
        self.width = int(width)
        self.alpha = float(alpha)
        self.dead_ratio = float(dead_ratio)
        self.dead_release = float(dead_release)
        self.hot_ratio = float(hot_ratio)
        self.hot_release = float(hot_release)
        self.dwell_frames = int(dwell_frames)
        self.activity_floor = float(activity_floor)
        self.jacobi_steps = int(jacobi_steps)
        self.device = torch.device(device)

        self._k8 = torch.ones((1, 1, 3, 3), dtype=torch.float32, device=self.device)
        self._k8[0, 0, 1, 1] = 0.0
        self._k4 = torch.tensor(
            [[[[0.0, 1.0, 0.0], [1.0, 0.0, 1.0], [0.0, 1.0, 0.0]]]],
            dtype=torch.float32,
            device=self.device,
        )
        ones = torch.ones((1, 1, self.height, self.width), dtype=torch.float32, device=self.device)
        self._n8 = F.conv2d(ones, self._k8, padding=1)[0, 0]
        self._n4 = F.conv2d(ones, self._k4, padding=1)[0, 0]
        self.reset()

    def reset(self) -> None:
        shape = (self.height, self.width)
        self.step_count = 0
        self.trace = torch.zeros(shape, dtype=torch.float32, device=self.device)
        self.dead_dwell = torch.zeros(shape, dtype=torch.int32, device=self.device)
        self.hot_dwell = torch.zeros(shape, dtype=torch.int32, device=self.device)
        self.zero_dwell = torch.zeros(shape, dtype=torch.int32, device=self.device)
        self.dead_trace_flag = torch.zeros(shape, dtype=torch.bool, device=self.device)
        self.dead_zero_flag = torch.zeros(shape, dtype=torch.bool, device=self.device)
        self.hot_flag = torch.zeros(shape, dtype=torch.bool, device=self.device)

    @property
    def flagged_mask(self) -> torch.Tensor:
        return self.dead_trace_flag | self.dead_zero_flag | self.hot_flag

    def _jacobi_fill(self, frame_2hw: torch.Tensor, mask_hw: torch.Tensor) -> torch.Tensor:
        if not bool(mask_hw.any()):
            return frame_2hw
        u = frame_2hw.clone()
        m = mask_hw.unsqueeze(0)
        fixed = ~m
        orig = frame_2hw
        k4 = self._k4.expand(2, 1, 3, 3)
        denom = self._n4.unsqueeze(0)
        for _ in range(self.jacobi_steps):
            neigh = F.conv2d(u.unsqueeze(0), k4, padding=1, groups=2)[0] / denom
            u = torch.where(fixed, orig, neigh)
        return u

    def _neighbor_mean(self, grid_hw: torch.Tensor) -> torch.Tensor:
        s = F.conv2d(grid_hw.unsqueeze(0).unsqueeze(0), self._k8, padding=1)[0, 0]
        return s / self._n8

    @torch.no_grad()
    def process_frame(self, frame_2hw: torch.Tensor) -> torch.Tensor:
        x = frame_2hw.to(device=self.device, dtype=torch.float32)
        pooled = x[0] + x[1]

        self.step_count += 1
        self.trace.mul_(1.0 - self.alpha).add_(self.alpha * pooled)
        denom = 1.0 - (1.0 - self.alpha) ** self.step_count
        b_nu = self.trace / denom

        cur_mask = self.flagged_mask
        filled_trace = b_nu
        if bool(cur_mask.any()):
            filled_trace = self._jacobi_fill(b_nu.unsqueeze(0).expand(2, -1, -1), cur_mask)[0]
        n_mean = self._neighbor_mean(filled_trace)
        active_nb = n_mean > self.activity_floor

        low_cond = active_nb & (b_nu < self.dead_ratio * n_mean)
        self.dead_dwell = torch.where(low_cond, self.dead_dwell + 1, torch.zeros_like(self.dead_dwell))
        self.dead_trace_flag = (self.dead_trace_flag | (self.dead_dwell >= self.dwell_frames)) & ~(
            b_nu > self.dead_release * n_mean
        )

        high_cond = active_nb & (b_nu > self.hot_ratio * n_mean)
        self.hot_dwell = torch.where(high_cond, self.hot_dwell + 1, torch.zeros_like(self.hot_dwell))
        self.hot_flag = (self.hot_flag | (self.hot_dwell >= self.dwell_frames)) & ~(
            b_nu < self.hot_release * n_mean
        )

        nb_event_mean = self._neighbor_mean(pooled)
        silent_cond = (pooled == 0.0) & (nb_event_mean > self.activity_floor)
        self.zero_dwell = torch.where(silent_cond, self.zero_dwell + 1, torch.zeros_like(self.zero_dwell))
        self.dead_zero_flag = (self.dead_zero_flag | (self.zero_dwell >= self.dwell_frames)) & (pooled == 0.0)

        out = self._jacobi_fill(x, self.flagged_mask)
        return out.to(device=frame_2hw.device, dtype=frame_2hw.dtype)

    @torch.no_grad()
    def process_clip(self, clip_t2hw: torch.Tensor) -> torch.Tensor:
        frames = [self.process_frame(clip_t2hw[t]) for t in range(clip_t2hw.shape[0])]
        return torch.stack(frames, dim=0)
