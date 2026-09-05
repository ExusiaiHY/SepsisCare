"""GRU-D recurrent cell with input/hidden decay and feature-group aware decay.

Reference:
    Che Z, et al. *Scientific Reports* 8:6085 (2018).
    Recurrent Neural Networks for Multivariate Time Series with Missing Values.

The cell implements::

    gamma_x = exp(-max(0, W_gx * delta + b_gx))           # per-feature input decay
    gamma_h = exp(-max(0, W_gh * delta_bar + b_gh))       # hidden-state decay
    x_hat   = m * x_obs + (1 - m) * (gamma_x * x_locf + (1 - gamma_x) * x_mean)
    h_decayed = gamma_h * h_prev
    h_t = GRUUpdate([x_hat ; m ; gamma_x ; side], h_decayed)

Feature groups (vitals vs labs/blood-gas) get distinct decay initialisations
matching the empirical pattern in
``outputs/reports/inconsistency_missingness_synthesis.md``: observation-class
features (resp_rate, gcs) decay fast; lab-class features (lactate, fio2,
paco2, ph) decay slowly.
"""
from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Sequence

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F


VITALS_GROUP = "vitals"
LABS_GROUP = "labs_and_gas"


def feature_groups_from_dict(
    feature_dict_path: Path,
    feature_names: Sequence[str],
) -> tuple[np.ndarray, dict[str, list[int]]]:
    """Resolve a per-feature group label and a name->indices map.

    Returns
    -------
    group_per_feature : np.ndarray of int, shape (len(feature_names),)
        0 for vitals, 1 for labs/blood_gas. Unknown features default to 1.
    group_indices : dict[str, list[int]]
        Indices grouped by VITALS_GROUP / LABS_GROUP keys.
    """
    group_per_feature = np.ones(len(feature_names), dtype=np.int64)
    group_indices: dict[str, list[int]] = {VITALS_GROUP: [], LABS_GROUP: []}
    if not feature_dict_path.exists():
        for idx in range(len(feature_names)):
            group_indices[LABS_GROUP].append(idx)
        return group_per_feature, group_indices

    try:
        feature_dict = json.loads(feature_dict_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        for idx in range(len(feature_names)):
            group_indices[LABS_GROUP].append(idx)
        return group_per_feature, group_indices

    by_name = {
        str(item.get("name", "")).lower(): item
        for item in feature_dict.get("continuous", [])
    }
    for idx, name in enumerate(feature_names):
        meta = by_name.get(str(name).lower(), {})
        norm = str(meta.get("normalization_group", "")).lower()
        if norm in {"vitals", "vital"}:
            group_per_feature[idx] = 0
            group_indices[VITALS_GROUP].append(idx)
        elif norm in {"labs", "lab", "blood_gas", "gas"}:
            group_per_feature[idx] = 1
            group_indices[LABS_GROUP].append(idx)
        else:
            group_per_feature[idx] = 1
            group_indices[LABS_GROUP].append(idx)
    return group_per_feature, group_indices


def _log_inverse_decay(target_at_unit: float) -> float:
    """Initialise so exp(-w*1) ~= target at delta=1, i.e. w = -log(target)."""
    target = float(min(max(target_at_unit, 1.0e-3), 0.999))
    return float(-math.log(target))


class GRUDCell(nn.Module):
    """One-step GRU-D update with per-feature-group decay.

    Parameters
    ----------
    n_continuous:
        Number of continuous features that go through the imputation/decay path.
    side_dim:
        Dimensionality of additional features concatenated post-imputation
        (proxy / interventions / intervention masks). They do not decay.
    hidden_dim:
        GRU hidden size.
    feature_groups:
        Length-`n_continuous` int array, 0 = vitals (fast decay), 1 = labs/gas
        (slow decay).
    init_decay_at_unit:
        ``(vitals_target, labs_target)``. Initialises ``W_gx`` so that with a
        unit normalised delta we get ``gamma_x == target``. Vitals defaults to
        ``0.5`` (half-life ~ 1 unit); labs to ``0.9`` (long memory).
    """

    def __init__(
        self,
        *,
        n_continuous: int,
        side_dim: int,
        hidden_dim: int,
        feature_groups: np.ndarray,
        init_decay_at_unit: tuple[float, float] = (0.5, 0.9),
    ) -> None:
        super().__init__()
        if int(n_continuous) <= 0:
            raise ValueError("n_continuous must be positive")
        self.n_continuous = int(n_continuous)
        self.side_dim = int(side_dim)
        self.hidden_dim = int(hidden_dim)

        groups = np.asarray(feature_groups, dtype=np.int64)
        if groups.size != self.n_continuous:
            raise ValueError("feature_groups length must equal n_continuous")
        groups = np.clip(groups, 0, 1)
        self.register_buffer("group_ids", torch.from_numpy(groups), persistent=True)

        self.gamma_x_weight = nn.Parameter(torch.empty(self.n_continuous))
        self.gamma_x_bias = nn.Parameter(torch.empty(self.n_continuous))

        self.gamma_h_weight = nn.Parameter(torch.empty(self.hidden_dim))
        self.gamma_h_bias = nn.Parameter(torch.empty(self.hidden_dim))

        cell_input_dim = self.n_continuous * 3 + self.side_dim
        self.gru_cell = nn.GRUCell(cell_input_dim, self.hidden_dim)

        self._init_parameters(init_decay_at_unit)

    def _init_parameters(self, init_decay_at_unit: tuple[float, float]) -> None:
        with torch.no_grad():
            vitals_w = _log_inverse_decay(init_decay_at_unit[0])
            labs_w = _log_inverse_decay(init_decay_at_unit[1])
            for idx in range(self.n_continuous):
                if int(self.group_ids[idx].item()) == 0:
                    self.gamma_x_weight[idx] = vitals_w
                else:
                    self.gamma_x_weight[idx] = labs_w
            self.gamma_x_bias.zero_()
            self.gamma_h_weight.fill_(0.5)
            self.gamma_h_bias.zero_()

    def forward(
        self,
        x_obs: torch.Tensor,
        m: torch.Tensor,
        delta: torch.Tensor,
        x_locf: torch.Tensor,
        x_mean: torch.Tensor,
        side: torch.Tensor | None,
        h_prev: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        """One-step update.

        x_obs, m, delta, x_locf : (B, n_continuous)
        x_mean : (n_continuous,) or (B, n_continuous)
        side   : (B, side_dim) or None when side_dim == 0
        h_prev : (B, hidden_dim)
        """
        if x_mean.dim() == 1:
            x_mean = x_mean.unsqueeze(0).expand_as(x_obs)

        gamma_x = torch.exp(-F.relu(self.gamma_x_weight * delta + self.gamma_x_bias))
        gamma_x = gamma_x.clamp(min=1.0e-6, max=1.0)

        x_hat = m * x_obs + (1.0 - m) * (gamma_x * x_locf + (1.0 - gamma_x) * x_mean)

        delta_mean = delta.mean(dim=-1, keepdim=True)
        gamma_h = torch.exp(-F.relu(self.gamma_h_weight * delta_mean + self.gamma_h_bias))
        gamma_h = gamma_h.clamp(min=1.0e-6, max=1.0)
        h_decayed = gamma_h * h_prev

        cell_input_parts = [x_hat, m, gamma_x]
        if side is not None and self.side_dim > 0:
            cell_input_parts.append(side)
        cell_input = torch.cat(cell_input_parts, dim=-1)
        h_next = self.gru_cell(cell_input, h_decayed)
        return h_next, x_hat
