from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, Optional, Tuple, Union

import numpy as np
import torch

TensorLike = Union[np.ndarray, torch.Tensor]

DATASET_DENSITY_RATIO: Dict[str, float] = {
    "dvs128_gesture": 1.0,
    "cifar10_dvs": 0.577,
    "n_caltech101": 0.323,
    "n_cars": 0.128,
}

SEVERITY_TABLE: Dict[str, Tuple[float, float, float, float, float]] = {
    "shot_noise": (0.303, 0.494, 0.716, 0.954, 1.23),
    "lowered_threshold": (2.02, 3.77, 5.72, 9.19, 16.0),
    "on_leak": (0.119, 0.188, 0.244, 0.309, 0.439),
    "flicker": (0.309, 0.474, 0.593, 0.739, 1.27),
    "event_loss": (0.614, 0.724, 0.79, 0.847, 0.908),
    "readout_saturation": (0.699, 0.352, 0.244, 0.143, 0.0638),
    "raised_threshold": (0.515, 0.315, 0.232, 0.167, 0.0954),
    "hot_pixels": (0.00557, 0.00967, 0.0161, 0.0279, 0.0777),
    "dead_lines": (0.0837, 0.12, 0.177, 0.326, 0.559),
    "dead_clusters": (0.37, 0.475, 0.611, 0.77, 0.935),
}

FAULT_FAMILIES: Tuple[str, ...] = tuple(SEVERITY_TABLE.keys())


@dataclass
class SensorDefectState:
    height: int
    width: int
    hot_order: np.ndarray
    hot_polarity: np.ndarray
    dead_row_order: np.ndarray
    dead_col_order: np.ndarray
    cluster_centers: np.ndarray


class EventCGenerator:
    def __init__(
        self,
        height: int,
        width: int,
        rho: float = 1.0,
        seed: int = 0,
        on_polarity_index: int = 1,
    ) -> None:
        self.height = int(height)
        self.width = int(width)
        self.rho = float(rho)
        self.on_index = int(on_polarity_index)
        self.off_index = 1 - self.on_index
        self.rng = np.random.default_rng(seed)
        self.defects = self._init_defects(np.random.default_rng(seed + 104729))

    def _init_defects(self, mask_rng: np.random.Generator) -> SensorDefectState:
        num_pixels = self.height * self.width
        hot_order = mask_rng.permutation(num_pixels)
        hot_polarity = mask_rng.integers(0, 2, size=num_pixels, dtype=np.int64)
        dead_row_order = mask_rng.permutation(self.height)
        dead_col_order = mask_rng.permutation(self.width)
        max_disks = max(256, num_pixels)
        cy = mask_rng.uniform(0.0, float(self.height), size=max_disks)
        cx = mask_rng.uniform(0.0, float(self.width), size=max_disks)
        cluster_centers = np.stack([cy, cx], axis=1)
        return SensorDefectState(
            height=self.height,
            width=self.width,
            hot_order=hot_order,
            hot_polarity=hot_polarity,
            dead_row_order=dead_row_order,
            dead_col_order=dead_col_order,
            cluster_centers=cluster_centers,
        )

    def _hot_mask(self, fraction: float) -> Tuple[np.ndarray, np.ndarray]:
        count = int(round(fraction * self.height * self.width))
        count = max(0, min(count, self.height * self.width))
        idx = self.defects.hot_order[:count]
        pol = self.defects.hot_polarity[:count]
        ys = idx // self.width
        xs = idx % self.width
        mask = np.zeros((2, self.height, self.width), dtype=bool)
        if count > 0:
            mask[pol, ys, xs] = True
        return mask[0], mask[1]

    def _dead_lines_mask(self, fraction: float) -> np.ndarray:
        n_rows = max(0, min(int(round(fraction * self.height)), self.height))
        n_cols = max(0, min(int(round(fraction * self.width)), self.width))
        mask = np.zeros((self.height, self.width), dtype=bool)
        if n_rows > 0:
            mask[self.defects.dead_row_order[:n_rows], :] = True
        if n_cols > 0:
            mask[:, self.defects.dead_col_order[:n_cols]] = True
        return mask

    def _dead_clusters_mask(self, fraction: float) -> np.ndarray:
        radius = min(self.height, self.width) / 16.0
        r2 = radius * radius
        yy, xx = np.ogrid[: self.height, : self.width]
        mask = np.zeros((self.height, self.width), dtype=bool)
        target = int(round(fraction * self.height * self.width))
        for cy, cx in self.defects.cluster_centers:
            if int(mask.sum()) >= target:
                break
            disk = (yy - cy) ** 2 + (xx - cx) ** 2 <= r2
            mask |= disk
        return mask

    def parameter(self, family: str, severity: int) -> float:
        if family not in SEVERITY_TABLE:
            raise ValueError(f"Unknown event-C family: {family}")
        if severity < 1 or severity > 5:
            raise ValueError(f"Severity must be in 1..5, got {severity}")
        return SEVERITY_TABLE[family][severity - 1]

    def apply(
        self,
        clip: TensorLike,
        family: str,
        severity: int = 3,
        param: Optional[float] = None,
    ) -> TensorLike:
        is_torch = isinstance(clip, torch.Tensor)
        orig_device = clip.device if is_torch else None
        orig_dtype = clip.dtype if is_torch else clip.dtype
        arr = clip.detach().cpu().numpy() if is_torch else np.asarray(clip)

        squeeze = False
        if arr.ndim == 4:
            arr = arr[None]
            squeeze = True
        if arr.ndim != 5 or arr.shape[2] != 2:
            raise ValueError(f"Expected shape (T, 2, H, W) or (B, T, 2, H, W), got {arr.shape}")
        if arr.shape[3] != self.height or arr.shape[4] != self.width:
            raise ValueError(
                f"Clip spatial size {arr.shape[3:]} does not match generator {(self.height, self.width)}"
            )

        p = self.parameter(family, severity) if param is None else float(param)
        x = np.maximum(np.rint(arr).astype(np.int64), 0)
        b, t, _, h, w = x.shape

        if family == "shot_noise":
            lam = max(0.0, self.rho * p * 0.5)
            y = x + self.rng.poisson(lam, size=x.shape)
        elif family == "lowered_threshold":
            y = self.rng.poisson(np.maximum(0.0, p * x.astype(np.float64)))
        elif family == "on_leak":
            y = x.copy()
            lam = max(0.0, self.rho * p)
            y[:, :, self.on_index] = y[:, :, self.on_index] + self.rng.poisson(lam, size=(b, t, h, w))
        elif family == "flicker":
            y = x.copy()
            frames = np.arange(t, dtype=np.float64)[None, :, None, None]
            phi = self.rng.uniform(0.0, 2.0 * np.pi, size=(b, 1, 1, 1))
            theta = (2.0 * np.pi * frames / 4.0) + phi
            lam_off = np.maximum(0.0, 0.5 * self.rho * p * (1.0 + np.cos(theta)))
            lam_on = np.maximum(0.0, 0.5 * self.rho * p * (1.0 + np.cos(theta - 0.5 * np.pi)))
            y[:, :, self.off_index] += self.rng.poisson(np.broadcast_to(lam_off, (b, t, h, w)))
            y[:, :, self.on_index] += self.rng.poisson(np.broadcast_to(lam_on, (b, t, h, w)))
        elif family == "event_loss":
            keep = float(np.clip(1.0 - p, 0.0, 1.0))
            y = self.rng.binomial(x, keep)
        elif family == "readout_saturation":
            budget = max(0.0, self.rho * p * h * w)
            totals = x.sum(axis=(2, 3, 4), keepdims=True).astype(np.float64)
            q = np.where(totals > 0.0, np.minimum(1.0, budget / np.maximum(totals, 1.0)), 1.0)
            y = self.rng.binomial(x, np.broadcast_to(q, x.shape))
        elif family == "raised_threshold":
            y = self.rng.poisson(np.maximum(0.0, p * x.astype(np.float64)))
        elif family == "hot_pixels":
            m0, m1 = self._hot_mask(p)
            y = x.copy()
            rate = max(0.0, 5.0 * self.rho)
            if m0.any():
                y[:, :, 0, m0] += self.rng.poisson(rate, size=(b, t, int(m0.sum())))
            if m1.any():
                y[:, :, 1, m1] += self.rng.poisson(rate, size=(b, t, int(m1.sum())))
        elif family == "dead_lines":
            dead = self._dead_lines_mask(p)
            y = x.copy()
            y[:, :, :, dead] = 0
        elif family == "dead_clusters":
            dead = self._dead_clusters_mask(p)
            y = x.copy()
            y[:, :, :, dead] = 0
        else:
            raise ValueError(f"Unknown event-C family: {family}")

        y = np.maximum(y, 0)
        if squeeze:
            y = y[0]
        if is_torch:
            return torch.from_numpy(y).to(device=orig_device, dtype=orig_dtype)
        return y.astype(orig_dtype, copy=False)


def apply_event_c(
    clip: TensorLike,
    family: str,
    severity: int = 3,
    dataset: str = "dvs128_gesture",
    rho: Optional[float] = None,
    seed: int = 0,
    on_polarity_index: int = 1,
) -> TensorLike:
    shape = clip.shape
    h, w = int(shape[-2]), int(shape[-1])
    density = DATASET_DENSITY_RATIO[dataset] if rho is None else float(rho)
    gen = EventCGenerator(h, w, rho=density, seed=seed, on_polarity_index=on_polarity_index)
    return gen.apply(clip, family=family, severity=severity)
