from __future__ import annotations

from typing import List, Tuple

import torch
import torch.nn as nn


class LIFNode(nn.Module):
    def __init__(self, tau: float = 2.0, v_threshold: float = 1.0, v_reset: float = 0.0) -> None:
        super().__init__()
        self.tau = float(tau)
        self.v_threshold = float(v_threshold)
        self.v_reset = float(v_reset)
        self.v: torch.Tensor | None = None

    def reset_state(self) -> None:
        self.v = None

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if self.v is None or self.v.shape != x.shape or self.v.device != x.device:
            self.v = torch.full_like(x, self.v_reset)
        h = self.v + (x - (self.v - self.v_reset)) / self.tau
        s = (h >= self.v_threshold).to(x.dtype)
        self.v = h * (1.0 - s) + self.v_reset * s
        return s


class ConvLIFBlock(nn.Module):
    def __init__(
        self,
        in_channels: int,
        out_channels: int,
        use_bn: bool = True,
        use_pool: bool = True,
        tau: float = 2.0,
    ) -> None:
        super().__init__()
        self.conv = nn.Conv2d(in_channels, out_channels, kernel_size=3, padding=1, bias=not use_bn)
        self.bn = nn.BatchNorm2d(out_channels) if use_bn else nn.Identity()
        self.lif = LIFNode(tau=tau)
        self.pool = nn.MaxPool2d(kernel_size=2, stride=2) if use_pool else nn.Identity()

    def reset_state(self) -> None:
        self.lif.reset_state()

    def current(self, x: torch.Tensor) -> torch.Tensor:
        return self.bn(self.conv(x))

    def activate(self, current: torch.Tensor) -> torch.Tensor:
        return self.pool(self.lif(current))


class FiveBlockSNN(nn.Module):
    def __init__(
        self,
        num_classes: int = 11,
        channels: Tuple[int, ...] = (128, 128, 128, 128, 128),
        in_channels: int = 2,
        input_size: int = 128,
        hidden_dim: int = 512,
        votes_per_class: int = 10,
        tau: float = 2.0,
    ) -> None:
        super().__init__()
        self.num_classes = int(num_classes)
        self.votes_per_class = int(votes_per_class)
        blocks: List[ConvLIFBlock] = []
        c_in = in_channels
        for c_out in channels:
            blocks.append(ConvLIFBlock(c_in, c_out, use_bn=True, use_pool=True, tau=tau))
            c_in = c_out
        self.blocks = nn.ModuleList(blocks)
        spatial = max(1, input_size // (2 ** len(channels)))
        flat_dim = channels[-1] * spatial * spatial
        self.fc1 = nn.Linear(flat_dim, hidden_dim, bias=True)
        self.lif_fc1 = LIFNode(tau=tau)
        self.fc2 = nn.Linear(hidden_dim, self.num_classes * self.votes_per_class, bias=True)
        self.lif_fc2 = LIFNode(tau=tau)

    def reset_state(self) -> None:
        for blk in self.blocks:
            blk.reset_state()
        self.lif_fc1.reset_state()
        self.lif_fc2.reset_state()

    def classify_features(self, feat: torch.Tensor) -> torch.Tensor:
        flat = feat.flatten(1)
        h = self.lif_fc1(self.fc1(flat))
        spikes = self.lif_fc2(self.fc2(h))
        return spikes.view(feat.shape[0], self.num_classes, self.votes_per_class).mean(dim=2)

    def forward(self, clip: torch.Tensor) -> torch.Tensor:
        squeeze = False
        if clip.ndim == 4:
            clip = clip.unsqueeze(0)
            squeeze = True
        self.reset_state()
        logits_acc = None
        for t in range(clip.shape[1]):
            h = clip[:, t]
            for blk in self.blocks:
                h = blk.activate(blk.current(h))
            out = self.classify_features(h)
            logits_acc = out if logits_acc is None else logits_acc + out
        logits = logits_acc / float(clip.shape[1])
        return logits[0] if squeeze else logits


class NCarsSNN(nn.Module):
    def __init__(
        self,
        num_classes: int = 2,
        channels: Tuple[int, ...] = (64, 128, 256, 256, 512, 512, 512, 512),
        in_channels: int = 2,
        input_size: int = 48,
        votes_per_class: int = 10,
        tau: float = 2.0,
    ) -> None:
        super().__init__()
        self.num_classes = int(num_classes)
        self.votes_per_class = int(votes_per_class)
        blocks: List[ConvLIFBlock] = []
        c_in = in_channels
        for idx, c_out in enumerate(channels):
            blocks.append(ConvLIFBlock(c_in, c_out, use_bn=False, use_pool=(idx % 2 == 1), tau=tau))
            c_in = c_out
        self.blocks = nn.ModuleList(blocks)
        num_pools = sum(1 for idx in range(len(channels)) if idx % 2 == 1)
        spatial = max(1, input_size // (2 ** num_pools))
        flat_dim = channels[-1] * spatial * spatial
        self.fc = nn.Linear(flat_dim, self.num_classes * self.votes_per_class, bias=True)
        self.lif_fc = LIFNode(tau=tau)

    def reset_state(self) -> None:
        for blk in self.blocks:
            blk.reset_state()
        self.lif_fc.reset_state()

    def classify_features(self, feat: torch.Tensor) -> torch.Tensor:
        spikes = self.lif_fc(self.fc(feat.flatten(1)))
        return spikes.view(feat.shape[0], self.num_classes, self.votes_per_class).mean(dim=2)

    def forward(self, clip: torch.Tensor) -> torch.Tensor:
        squeeze = False
        if clip.ndim == 4:
            clip = clip.unsqueeze(0)
            squeeze = True
        self.reset_state()
        logits_acc = None
        for t in range(clip.shape[1]):
            h = clip[:, t]
            for blk in self.blocks:
                h = blk.activate(blk.current(h))
            out = self.classify_features(h)
            logits_acc = out if logits_acc is None else logits_acc + out
        logits = logits_acc / float(clip.shape[1])
        return logits[0] if squeeze else logits
