"""Prediction-guided trajectory encoder for phenotype consistency experiments.

This module implements a leakage-aware experiment inspired by
prediction-guided clustering:

1. Train a GRU/LSTM encoder on clinical trajectory auxiliary tasks.
2. Fit a current-window phenotype readout on train-only encoder embeddings.
3. Smooth phenotype probabilities with a train-only transition matrix.
4. Compare raw rule, rule + smoothing, encoder, encoder + smoothing.

The encoder never sees validation/test phenotype labels during fitting. The
transition matrix, LOS normalization, and readout classifier are fit only on
the train patient split.
"""
from __future__ import annotations

import copy
import json
import math
import pickle
import time
from collections import OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pandas as pd
import torch
import torch.nn as nn
import torch.nn.functional as F
from scipy.optimize import linear_sum_assignment
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import f1_score, mean_absolute_error, roc_auc_score
from sklearn.pipeline import make_pipeline
from sklearn.preprocessing import StandardScaler
from torch.nn.utils.rnn import pack_padded_sequence
from torch.utils.data import DataLoader, Dataset


FEATURE_ALIASES = {
    "heart_rate": ("heart_rate", "hr"),
    "sbp": ("sbp", "systolic_bp"),
    "dbp": ("dbp", "diastolic_bp"),
    "map": ("map", "mbp"),
    "resp_rate": ("resp_rate", "rr"),
    "spo2": ("spo2", "sao2"),
    "temperature": ("temperature", "temp"),
    "creatinine": ("creatinine", "creat"),
    "wbc": ("wbc",),
    "lactate": ("lactate",),
}


@dataclass
class TrajectoryData:
    continuous: np.ndarray
    masks_continuous: np.ndarray
    proxy_indicators: np.ndarray
    interventions: np.ndarray
    masks_interventions: np.ndarray
    raw_continuous: np.ndarray
    raw_masks_continuous: np.ndarray
    static: pd.DataFrame
    phenotype_labels: np.ndarray
    splits: dict[str, np.ndarray]
    window_starts: list[int]
    window_len: int
    stride: int
    feature_names: list[str]
    feature_medians: np.ndarray
    next_mv_labels: np.ndarray
    next_mv_masks: np.ndarray
    next_rrt_labels: np.ndarray
    next_rrt_masks: np.ndarray
    remaining_los_hours: np.ndarray
    sepsis_labels: np.ndarray
    sepsis_masks: np.ndarray

    @property
    def n_patients(self) -> int:
        return int(self.phenotype_labels.shape[0])

    @property
    def n_windows(self) -> int:
        return int(self.phenotype_labels.shape[1])

    @property
    def n_classes(self) -> int:
        if self.phenotype_labels.size == 0:
            return 1
        return int(np.nanmax(self.phenotype_labels)) + 1

    @property
    def input_dim(self) -> int:
        return int(
            self.continuous.shape[-1]
            + self.masks_continuous.shape[-1]
            + self.proxy_indicators.shape[-1]
            + self.interventions.shape[-1]
            + self.masks_interventions.shape[-1]
        )


def _read_json(path: Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def _as_int_array(values: Any) -> np.ndarray:
    return np.asarray(values, dtype=np.int64)


def _load_feature_names(feature_dict_path: Path) -> list[str]:
    feature_dict = _read_json(feature_dict_path)
    continuous = sorted(feature_dict.get("continuous", []), key=lambda item: int(item.get("index", 0)))
    return [str(item.get("name", f"feature_{i}")) for i, item in enumerate(continuous)]


def _load_feature_medians(preprocess_stats_path: Path, n_features: int) -> np.ndarray:
    if preprocess_stats_path.exists():
        stats = _read_json(preprocess_stats_path)
        medians = np.asarray(stats.get("feature_medians", []), dtype=np.float32)
        if len(medians) >= n_features:
            return medians[:n_features]
    return np.zeros(n_features, dtype=np.float32)


def _load_splits(splits_path: Path, n_patients: int, seed: int) -> dict[str, np.ndarray]:
    if splits_path.exists():
        raw = _read_json(splits_path)
        out = {
            "train": _as_int_array(raw["train"]),
            "val": _as_int_array(raw["val"]),
            "test": _as_int_array(raw["test"]),
        }
        return out

    rng = np.random.default_rng(seed)
    idx = rng.permutation(np.arange(n_patients))
    n_train = int(round(0.7 * n_patients))
    n_val = int(round(0.15 * n_patients))
    return {
        "train": np.sort(idx[:n_train]),
        "val": np.sort(idx[n_train : n_train + n_val]),
        "test": np.sort(idx[n_train + n_val :]),
    }


def _safe_load_array(path: Path, shape: tuple[int, int, int], fill: float) -> np.ndarray:
    if path.exists():
        return np.load(path, mmap_mode="r")
    return np.full(shape, fill, dtype=np.float32)


def _find_feature(feature_names: list[str], canonical: str) -> int | None:
    normalized = {name.lower(): i for i, name in enumerate(feature_names)}
    for alias in FEATURE_ALIASES.get(canonical, (canonical,)):
        if alias.lower() in normalized:
            return normalized[alias.lower()]
    return None


def _future_binary_target(
    values: np.ndarray,
    masks: np.ndarray | None,
    *,
    window_starts: list[int],
    window_len: int,
    stride: int,
    feature_idx: int,
) -> tuple[np.ndarray, np.ndarray]:
    n_patients = values.shape[0]
    n_windows = len(window_starts)
    labels = np.zeros((n_patients, n_windows), dtype=np.float32)
    target_masks = np.zeros((n_patients, n_windows), dtype=np.float32)
    total_hours = values.shape[1]

    for wi, start in enumerate(window_starts):
        current_end = min(int(start) + int(window_len), total_hours)
        next_end = min(current_end + int(stride), total_hours)
        if next_end <= current_end:
            continue
        chunk = values[:, current_end:next_end, feature_idx]
        if masks is None:
            obs = np.ones_like(chunk, dtype=bool)
        else:
            obs = masks[:, current_end:next_end, feature_idx] > 0
        target_masks[:, wi] = obs.any(axis=1).astype(np.float32)
        labels[:, wi] = ((chunk > 0.5) & obs).any(axis=1).astype(np.float32)
    return labels, target_masks


def load_trajectory_data(
    *,
    s0_dir: Path,
    s2_dir: Path | None,
    splits_path: Path | None = None,
    seed: int = 42,
) -> TrajectoryData:
    """Load S0/S2 artifacts and build auxiliary targets.

    Future treatment labels are defined on the non-overlapping future stride
    after each current window. This avoids using overlapping next-window hours
    that are already visible in the current 24 h window.
    """
    s0_dir = Path(s0_dir)
    s2_dir = Path(s2_dir) if s2_dir is not None else None
    processed = s0_dir / "processed"
    raw_aligned = s0_dir / "raw_aligned"

    continuous = np.load(processed / "continuous.npy", mmap_mode="r")
    masks_continuous = np.load(processed / "masks_continuous.npy", mmap_mode="r")
    n_patients, n_hours, _ = continuous.shape
    proxy_indicators = _safe_load_array(
        processed / "proxy_indicators.npy",
        (n_patients, n_hours, 0),
        0.0,
    )
    interventions = _safe_load_array(
        processed / "interventions.npy",
        (n_patients, n_hours, 0),
        np.nan,
    )
    masks_interventions = _safe_load_array(
        processed / "masks_interventions.npy",
        (n_patients, n_hours, interventions.shape[-1]),
        0.0,
    )

    raw_continuous = _safe_load_array(raw_aligned / "continuous.npy", continuous.shape, np.nan)
    raw_masks_continuous = _safe_load_array(raw_aligned / "masks_continuous.npy", masks_continuous.shape, 0.0)

    static = pd.read_csv(s0_dir / "static.csv")
    if s2_dir is not None and (s2_dir / "window_labels.npy").exists():
        phenotype_labels = np.load(s2_dir / "window_labels.npy")
        rolling_meta = _read_json(s2_dir / "rolling_meta.json")
    else:
        rolling_meta = {
            "window_starts": [0, 6, 12, 18, 24],
            "window_len": 24,
            "stride": 6,
        }
        phenotype_labels = np.zeros((n_patients, len(rolling_meta["window_starts"])), dtype=np.int64)
    window_starts = [int(x) for x in rolling_meta.get("window_starts", [0, 6, 12, 18, 24])]
    window_len = int(rolling_meta.get("window_len", 24))
    if len(window_starts) > 1:
        stride = int(rolling_meta.get("stride", window_starts[1] - window_starts[0]))
    else:
        stride = int(rolling_meta.get("stride", 6))

    splits = _load_splits(splits_path or (s0_dir / "splits.json"), n_patients, seed)
    feature_names = _load_feature_names(s0_dir / "feature_dict.json")
    feature_medians = _load_feature_medians(processed / "preprocess_stats.json", len(feature_names))

    mechvent_idx = 1 if proxy_indicators.shape[-1] > 1 else None
    if mechvent_idx is not None:
        next_mv_labels, next_mv_masks = _future_binary_target(
            proxy_indicators,
            None,
            window_starts=window_starts,
            window_len=window_len,
            stride=stride,
            feature_idx=mechvent_idx,
        )
    else:
        next_mv_labels = np.zeros_like(phenotype_labels, dtype=np.float32)
        next_mv_masks = np.zeros_like(phenotype_labels, dtype=np.float32)

    rrt_idx = 1 if interventions.shape[-1] > 1 else None
    if rrt_idx is not None:
        next_rrt_labels, next_rrt_masks = _future_binary_target(
            np.nan_to_num(np.asarray(interventions), nan=0.0),
            np.asarray(masks_interventions),
            window_starts=window_starts,
            window_len=window_len,
            stride=stride,
            feature_idx=rrt_idx,
        )
    else:
        next_rrt_labels = np.zeros_like(phenotype_labels, dtype=np.float32)
        next_rrt_masks = np.zeros_like(phenotype_labels, dtype=np.float32)

    los_col = "icu_los_hours" if "icu_los_hours" in static.columns else None
    if los_col is None and "los_icu_days" in static.columns:
        los_hours = pd.to_numeric(static["los_icu_days"], errors="coerce").fillna(0.0).to_numpy(dtype=np.float32) * 24.0
    elif los_col is not None:
        los_hours = pd.to_numeric(static[los_col], errors="coerce").fillna(0.0).to_numpy(dtype=np.float32)
    else:
        los_hours = np.zeros(n_patients, dtype=np.float32)

    remaining_los = np.zeros_like(phenotype_labels, dtype=np.float32)
    for wi, start in enumerate(window_starts):
        current_end = min(int(start) + int(window_len), n_hours)
        remaining_los[:, wi] = np.maximum(los_hours - float(current_end), 0.0)

    if "sepsis_label" in static.columns:
        sepsis = pd.to_numeric(static["sepsis_label"], errors="coerce").to_numpy(dtype=np.float32)
        sepsis_masks = np.isfinite(sepsis).astype(np.float32)
        sepsis_labels = np.nan_to_num(sepsis, nan=0.0).astype(np.float32)
    else:
        sepsis_labels = np.zeros(n_patients, dtype=np.float32)
        sepsis_masks = np.zeros(n_patients, dtype=np.float32)

    return TrajectoryData(
        continuous=continuous,
        masks_continuous=masks_continuous,
        proxy_indicators=proxy_indicators,
        interventions=interventions,
        masks_interventions=masks_interventions,
        raw_continuous=raw_continuous,
        raw_masks_continuous=raw_masks_continuous,
        static=static,
        phenotype_labels=phenotype_labels.astype(np.int64, copy=False),
        splits=splits,
        window_starts=window_starts,
        window_len=window_len,
        stride=stride,
        feature_names=feature_names,
        feature_medians=feature_medians,
        next_mv_labels=next_mv_labels,
        next_mv_masks=next_mv_masks,
        next_rrt_labels=next_rrt_labels,
        next_rrt_masks=next_rrt_masks,
        remaining_los_hours=remaining_los,
        sepsis_labels=sepsis_labels,
        sepsis_masks=sepsis_masks,
    )


class TrajectoryWindowDataset(Dataset):
    def __init__(
        self,
        data: TrajectoryData,
        patient_indices: np.ndarray,
        *,
        los_mean: float,
        los_std: float,
        include_patient_window: bool = False,
        source_id: int | None = None,
        missingness_aware: bool = False,
        delta_clip_hours: float = 48.0,
        gru_d_imputation: bool = False,
    ):
        self.data = data
        self.patient_indices = np.asarray(patient_indices, dtype=np.int64)
        self.n_windows = data.n_windows
        self.los_mean = float(los_mean)
        self.los_std = max(float(los_std), 1.0e-6)
        self.include_patient_window = include_patient_window
        self.source_id = source_id
        self.missingness_aware = bool(missingness_aware)
        self.delta_clip_hours = max(float(delta_clip_hours), 1.0)
        self.gru_d_imputation = bool(gru_d_imputation)
        self._delta_cache: OrderedDict[int, tuple[np.ndarray, np.ndarray]] = OrderedDict()
        self._delta_cache_max = 8192
        self._locf_cache: OrderedDict[int, np.ndarray] = OrderedDict()
        self._locf_cache_max = 4096

    def __len__(self) -> int:
        return int(len(self.patient_indices) * self.n_windows)

    def _build_x(self, patient_idx: int, window_idx: int) -> tuple[np.ndarray, int]:
        start = self.data.window_starts[window_idx]
        length = min(int(start) + int(self.data.window_len), self.data.continuous.shape[1])
        continuous = np.nan_to_num(np.asarray(self.data.continuous[patient_idx]), nan=0.0)
        masks_cont = np.asarray(self.data.masks_continuous[patient_idx])
        proxy = np.nan_to_num(np.asarray(self.data.proxy_indicators[patient_idx]), nan=0.0)
        interventions = np.nan_to_num(np.asarray(self.data.interventions[patient_idx]), nan=0.0)
        masks_interventions = np.asarray(self.data.masks_interventions[patient_idx])
        pieces = [continuous, masks_cont, proxy, interventions, masks_interventions]
        if self.missingness_aware:
            delta_cont, delta_interventions = self._missingness_deltas(patient_idx, masks_cont, masks_interventions)
            pieces.extend([delta_cont, delta_interventions])
        x = np.concatenate(pieces, axis=-1).astype(np.float32, copy=False)
        if length < x.shape[0]:
            x = x.copy()
            x[length:, :] = 0.0
        return x, length

    def _build_gru_d_streams(
        self,
        patient_idx: int,
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
        """Compute (x_obs_cont, m_cont, delta_cont, x_locf_cont, side_feats) for one patient.

        ``x_obs_cont`` uses the post-imputation continuous block (so when m=1
        we feed the actual observed value); ``x_locf_cont`` carries the last
        observed raw value forward, falling back to feature_medians when no
        prior observation exists.
        """
        masks_cont = np.array(self.data.masks_continuous[patient_idx], dtype=np.float32, copy=True)
        x_obs = np.nan_to_num(np.asarray(self.data.continuous[patient_idx]), nan=0.0).astype(np.float32, copy=True)
        proxy = np.nan_to_num(np.asarray(self.data.proxy_indicators[patient_idx]), nan=0.0).astype(np.float32, copy=True)
        interventions = np.nan_to_num(np.asarray(self.data.interventions[patient_idx]), nan=0.0).astype(np.float32, copy=True)
        masks_interventions = np.array(self.data.masks_interventions[patient_idx], dtype=np.float32, copy=True)

        delta_cont, delta_interventions = self._missingness_deltas(patient_idx, masks_cont, masks_interventions)
        x_locf = self._build_locf(patient_idx, masks_cont)

        side_pieces = [proxy, interventions, masks_interventions]
        if self.missingness_aware:
            side_pieces.append(delta_interventions)
        side = np.concatenate(side_pieces, axis=-1).astype(np.float32, copy=False)
        return x_obs, masks_cont, delta_cont, x_locf, side

    def _build_locf(self, patient_idx: int, masks_cont: np.ndarray) -> np.ndarray:
        cached = self._locf_cache.get(patient_idx)
        if cached is not None:
            self._locf_cache.move_to_end(patient_idx)
            return cached
        raw_values = np.asarray(self.data.raw_continuous[patient_idx], dtype=np.float32)
        raw_mask_arr = self.data.raw_masks_continuous[patient_idx]
        raw_mask = np.asarray(raw_mask_arr, dtype=np.float32) if raw_mask_arr.size else masks_cont
        if raw_mask.shape != masks_cont.shape:
            raw_mask = masks_cont
        observed = (raw_mask > 0) & np.isfinite(raw_values)
        n_hours, n_features = raw_values.shape
        medians = np.asarray(self.data.feature_medians, dtype=np.float32)
        if medians.size < n_features:
            medians = np.concatenate([medians, np.zeros(n_features - medians.size, dtype=np.float32)])
        else:
            medians = medians[:n_features]
        last = np.broadcast_to(medians, (n_features,)).copy()
        locf = np.empty_like(raw_values, dtype=np.float32)
        for hour in range(n_hours):
            row_obs = observed[hour]
            if row_obs.any():
                last = np.where(row_obs, raw_values[hour], last)
            locf[hour] = last
        locf = np.nan_to_num(locf, nan=0.0)
        self._locf_cache[patient_idx] = locf
        if len(self._locf_cache) > self._locf_cache_max:
            self._locf_cache.popitem(last=False)
        return locf

    def _missingness_deltas(
        self,
        patient_idx: int,
        masks_cont: np.ndarray,
        masks_interventions: np.ndarray,
    ) -> tuple[np.ndarray, np.ndarray]:
        cached = self._delta_cache.get(patient_idx)
        if cached is not None:
            self._delta_cache.move_to_end(patient_idx)
            return cached
        value = (
            _time_since_observed(masks_cont, clip_hours=self.delta_clip_hours),
            _time_since_observed(masks_interventions, clip_hours=self.delta_clip_hours),
        )
        self._delta_cache[patient_idx] = value
        if len(self._delta_cache) > self._delta_cache_max:
            self._delta_cache.popitem(last=False)
        return value

    def __getitem__(self, sample_idx: int) -> dict[str, torch.Tensor]:
        row = int(sample_idx // self.n_windows)
        window_idx = int(sample_idx % self.n_windows)
        patient_idx = int(self.patient_indices[row])
        x, length = self._build_x(patient_idx, window_idx)
        mortality_col = "mortality_inhospital"
        if mortality_col not in self.data.static.columns and "mortality_28d" in self.data.static.columns:
            mortality_col = "mortality_28d"
        mortality = float(pd.to_numeric(self.data.static.iloc[patient_idx].get(mortality_col, 0), errors="coerce"))
        if not math.isfinite(mortality):
            mortality = 0.0

        los_target = math.log1p(float(self.data.remaining_los_hours[patient_idx, window_idx]))
        los_target = (los_target - self.los_mean) / self.los_std

        out: dict[str, torch.Tensor] = {
            "x": torch.from_numpy(x),
            "length": torch.tensor(length, dtype=torch.long),
            "y_mortality": torch.tensor(mortality, dtype=torch.float32),
            "y_sepsis": torch.tensor(float(self.data.sepsis_labels[patient_idx]), dtype=torch.float32),
            "mask_sepsis": torch.tensor(float(self.data.sepsis_masks[patient_idx]), dtype=torch.float32),
            "y_los": torch.tensor(los_target, dtype=torch.float32),
            "y_next_mv": torch.tensor(float(self.data.next_mv_labels[patient_idx, window_idx]), dtype=torch.float32),
            "mask_next_mv": torch.tensor(float(self.data.next_mv_masks[patient_idx, window_idx]), dtype=torch.float32),
            "y_next_rrt": torch.tensor(float(self.data.next_rrt_labels[patient_idx, window_idx]), dtype=torch.float32),
            "mask_next_rrt": torch.tensor(float(self.data.next_rrt_masks[patient_idx, window_idx]), dtype=torch.float32),
            "y_phenotype": torch.tensor(int(self.data.phenotype_labels[patient_idx, window_idx]), dtype=torch.long),
            "window_idx": torch.tensor(window_idx, dtype=torch.long),
        }
        if self.include_patient_window:
            out["patient_idx"] = torch.tensor(patient_idx, dtype=torch.long)
        if self.source_id is not None:
            out["source_id"] = torch.tensor(int(self.source_id), dtype=torch.long)
        if self.gru_d_imputation:
            x_obs_cont, m_cont, delta_cont, x_locf_cont, side = self._build_gru_d_streams(patient_idx)
            if length < x_obs_cont.shape[0]:
                x_obs_cont = x_obs_cont.copy(); x_obs_cont[length:, :] = 0.0
                m_cont = m_cont.copy(); m_cont[length:, :] = 0.0
                delta_cont = delta_cont.copy(); delta_cont[length:, :] = 0.0
                x_locf_cont = x_locf_cont.copy(); x_locf_cont[length:, :] = 0.0
                side = side.copy(); side[length:, :] = 0.0
            out["x_obs_cont"] = torch.from_numpy(x_obs_cont)
            out["m_cont"] = torch.from_numpy(m_cont)
            out["delta_cont"] = torch.from_numpy(delta_cont)
            out["x_locf_cont"] = torch.from_numpy(x_locf_cont)
            out["side_feats"] = torch.from_numpy(side)
        return out


def _time_since_observed(mask: np.ndarray, *, clip_hours: float = 48.0) -> np.ndarray:
    mask_arr = np.asarray(mask)
    if mask_arr.size == 0:
        return np.zeros_like(mask_arr, dtype=np.float32)
    observed = mask_arr > 0
    n_hours, n_features = observed.shape
    last_seen = np.full(n_features, -1, dtype=np.int32)
    delta = np.zeros((n_hours, n_features), dtype=np.float32)
    clip = float(max(clip_hours, 1.0))
    for hour in range(n_hours):
        seen = observed[hour]
        last_seen[seen] = hour
        raw_delta = np.where(last_seen >= 0, hour - last_seen, clip)
        delta[hour] = np.minimum(raw_delta.astype(np.float32), clip) / clip
    return delta


def _model_input_dim(data: TrajectoryData, *, missingness_aware: bool) -> int:
    dim = data.input_dim
    if missingness_aware:
        dim += int(data.masks_continuous.shape[-1])
        dim += int(data.masks_interventions.shape[-1])
    return int(dim)


class _GradientReversal(torch.autograd.Function):
    @staticmethod
    def forward(ctx: Any, x: torch.Tensor, strength: float) -> torch.Tensor:
        ctx.strength = float(strength)
        return x.view_as(x)

    @staticmethod
    def backward(ctx: Any, grad_output: torch.Tensor) -> tuple[torch.Tensor, None]:
        return -ctx.strength * grad_output, None


def _gradient_reverse(x: torch.Tensor, strength: float) -> torch.Tensor:
    return _GradientReversal.apply(x, float(strength))


class TrajectoryEncoderModel(nn.Module):
    def __init__(
        self,
        *,
        input_dim: int,
        hidden_dim: int = 64,
        embedding_dim: int = 64,
        recurrent: str = "gru",
        num_layers: int = 1,
        dropout: float = 0.1,
        n_sources: int = 0,
        n_phenotype_classes: int = 0,
        use_gru_d: bool = False,
        gru_d_n_continuous: int = 0,
        gru_d_side_dim: int = 0,
        gru_d_feature_groups: np.ndarray | None = None,
        gru_d_feature_means: np.ndarray | None = None,
    ):
        super().__init__()
        self.recurrent = recurrent.lower()
        self.n_sources = int(n_sources)
        self.n_phenotype_classes = int(n_phenotype_classes)
        self.use_gru_d = bool(use_gru_d)
        rnn_dropout = dropout if num_layers > 1 else 0.0
        rnn_cls: type[nn.GRU] | type[nn.LSTM]
        if self.recurrent == "gru":
            rnn_cls = nn.GRU
        elif self.recurrent == "lstm":
            rnn_cls = nn.LSTM
        else:
            raise ValueError(f"Unsupported recurrent encoder: {recurrent}")

        if self.use_gru_d:
            from s6.grud_cell import GRUDCell

            if gru_d_feature_groups is None:
                raise ValueError("gru_d_feature_groups required when use_gru_d=True")
            if gru_d_feature_means is None:
                raise ValueError("gru_d_feature_means required when use_gru_d=True")
            self.input_norm = nn.Identity()
            self.rnn = None
            self.grud_cell = GRUDCell(
                n_continuous=int(gru_d_n_continuous),
                side_dim=int(gru_d_side_dim),
                hidden_dim=int(hidden_dim),
                feature_groups=np.asarray(gru_d_feature_groups, dtype=np.int64),
            )
            mean_tensor = torch.as_tensor(np.asarray(gru_d_feature_means, dtype=np.float32))
            self.register_buffer("grud_feature_means", mean_tensor, persistent=True)
            self.gru_d_n_continuous = int(gru_d_n_continuous)
            self.gru_d_side_dim = int(gru_d_side_dim)
        else:
            self.input_norm = nn.LayerNorm(input_dim)
            self.rnn = rnn_cls(
                input_dim,
                hidden_dim,
                num_layers=num_layers,
                batch_first=True,
                dropout=rnn_dropout,
            )
            self.grud_cell = None

        self.hidden_dim = int(hidden_dim)
        self.embedding = nn.Sequential(
            nn.LayerNorm(hidden_dim),
            nn.Linear(hidden_dim, embedding_dim),
            nn.GELU(),
            nn.Dropout(dropout),
        )
        self.head_mortality = nn.Linear(embedding_dim, 1)
        self.head_sepsis = nn.Linear(embedding_dim, 1)
        self.head_los = nn.Linear(embedding_dim, 1)
        self.head_next_mv = nn.Linear(embedding_dim, 1)
        self.head_next_rrt = nn.Linear(embedding_dim, 1)
        self.head_source = nn.Linear(embedding_dim, self.n_sources) if self.n_sources > 1 else None
        self.head_phenotype = (
            nn.Linear(embedding_dim, self.n_phenotype_classes)
            if self.n_phenotype_classes > 1
            else None
        )

    def encode(self, x: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
        x = self.input_norm(x)
        lengths_cpu = lengths.detach().cpu().clamp(min=1)
        packed = pack_padded_sequence(x, lengths_cpu, batch_first=True, enforce_sorted=False)
        _, hidden = self.rnn(packed)
        if isinstance(hidden, tuple):
            hidden = hidden[0]
        last = hidden[-1]
        return self.embedding(last)

    def encode_gru_d(
        self,
        x_obs_cont: torch.Tensor,
        m_cont: torch.Tensor,
        delta_cont: torch.Tensor,
        x_locf_cont: torch.Tensor,
        side_feats: torch.Tensor,
        lengths: torch.Tensor,
    ) -> torch.Tensor:
        """Sequential GRU-D rollout returning the last-valid-step hidden embedding.

        Decay and imputation are computed vectorised over the whole time axis
        once; only the per-step GRU update remains inside the Python loop.
        """
        if self.grud_cell is None:
            raise RuntimeError("encode_gru_d called but use_gru_d=False")
        batch_size, seq_len, _ = x_obs_cont.shape
        device = x_obs_cont.device
        dtype = x_obs_cont.dtype
        cell = self.grud_cell

        x_mean = self.grud_feature_means.to(dtype=dtype, device=device)
        x_mean_expanded = x_mean.view(1, 1, -1).expand(batch_size, seq_len, -1)

        gamma_x = torch.exp(
            -F.relu(cell.gamma_x_weight * delta_cont + cell.gamma_x_bias)
        ).clamp(min=1.0e-6, max=1.0)
        x_hat_full = m_cont * x_obs_cont + (1.0 - m_cont) * (
            gamma_x * x_locf_cont + (1.0 - gamma_x) * x_mean_expanded
        )

        delta_mean = delta_cont.mean(dim=-1, keepdim=True)
        gamma_h_full = torch.exp(
            -F.relu(cell.gamma_h_weight * delta_mean + cell.gamma_h_bias)
        ).clamp(min=1.0e-6, max=1.0)

        if self.gru_d_side_dim > 0:
            cell_input_full = torch.cat([x_hat_full, m_cont, gamma_x, side_feats], dim=-1)
        else:
            cell_input_full = torch.cat([x_hat_full, m_cont, gamma_x], dim=-1)

        h_t = torch.zeros(batch_size, self.hidden_dim, device=device, dtype=dtype)
        last_hidden = torch.zeros_like(h_t)
        last_step_idx = (lengths.clamp(min=1) - 1).to(device)
        for t in range(seq_len):
            h_decayed = gamma_h_full[:, t] * h_t
            h_t = cell.gru_cell(cell_input_full[:, t], h_decayed)
            keep = (last_step_idx == t).to(dtype=dtype).unsqueeze(-1)
            last_hidden = last_hidden + keep * h_t
        return self.embedding(last_hidden)

    def forward(
        self,
        x: torch.Tensor,
        lengths: torch.Tensor,
        *,
        grl_lambda: float = 0.0,
        gru_d_inputs: dict[str, torch.Tensor] | None = None,
    ) -> dict[str, torch.Tensor]:
        if self.use_gru_d:
            if gru_d_inputs is None:
                raise ValueError("gru_d_inputs required when use_gru_d=True")
            emb = self.encode_gru_d(
                gru_d_inputs["x_obs_cont"],
                gru_d_inputs["m_cont"],
                gru_d_inputs["delta_cont"],
                gru_d_inputs["x_locf_cont"],
                gru_d_inputs["side_feats"],
                lengths,
            )
        else:
            emb = self.encode(x, lengths)
        out = {
            "embedding": emb,
            "logits_mortality": self.head_mortality(emb).squeeze(-1),
            "logits_sepsis": self.head_sepsis(emb).squeeze(-1),
            "pred_los": self.head_los(emb).squeeze(-1),
            "logits_next_mv": self.head_next_mv(emb).squeeze(-1),
            "logits_next_rrt": self.head_next_rrt(emb).squeeze(-1),
        }
        if self.head_source is not None:
            source_emb = _gradient_reverse(emb, grl_lambda) if grl_lambda > 0 else emb
            out["logits_source"] = self.head_source(source_emb)
        if self.head_phenotype is not None:
            out["logits_phenotype"] = self.head_phenotype(emb)
        return out


def _gru_d_inputs_from_batch(
    model: "TrajectoryEncoderModel",
    batch: dict[str, torch.Tensor],
    device: str | torch.device,
) -> dict[str, torch.Tensor] | None:
    """Move GRU-D streams to device when the model wants them; else None."""
    if not getattr(_unwrap_model(model), "use_gru_d", False):
        return None
    keys = ("x_obs_cont", "m_cont", "delta_cont", "x_locf_cont", "side_feats")
    return {k: batch[k].to(device) for k in keys}


def _unwrap_model(model: nn.Module) -> nn.Module:
    """Return the underlying module when training through DataParallel."""
    return model.module if isinstance(model, nn.DataParallel) else model


def _state_dict_for_save(model: nn.Module) -> dict[str, torch.Tensor]:
    return _unwrap_model(model).state_dict()


def _load_model_state(model: nn.Module, state: dict[str, torch.Tensor]) -> None:
    _unwrap_model(model).load_state_dict(state)


def _maybe_wrap_data_parallel(model: nn.Module, device: str) -> tuple[nn.Module, int]:
    if str(device).startswith("cuda") and torch.cuda.is_available() and torch.cuda.device_count() > 1:
        return nn.DataParallel(model), int(torch.cuda.device_count())
    return model, 1


def _forward_model(
    model: nn.Module,
    batch: dict[str, torch.Tensor],
    *,
    device: str | torch.device,
    grl_lambda: float = 0.0,
) -> dict[str, torch.Tensor]:
    """Run the encoder while avoiding DataParallel empty shards on tiny batches."""
    target_model = model
    if isinstance(model, nn.DataParallel):
        if not model.training:
            target_model = model.module
    return target_model(
        batch["x"].to(device),
        batch["length"].to(device),
        grl_lambda=grl_lambda,
        gru_d_inputs=_gru_d_inputs_from_batch(target_model, batch, device),
    )


def _masked_bce(logits: torch.Tensor, target: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    if float(mask.sum().detach().cpu()) <= 0.0:
        return logits.sum() * 0.0
    loss = F.binary_cross_entropy_with_logits(logits, target, reduction="none")
    return (loss * mask).sum() / mask.sum().clamp(min=1.0)


def _supervised_contrastive_loss(
    embeddings: torch.Tensor,
    labels: torch.Tensor,
    *,
    temperature: float = 0.2,
) -> torch.Tensor:
    """Supervised contrastive loss over phenotype labels."""
    if embeddings.shape[0] <= 1:
        return embeddings.sum() * 0.0
    labels = labels.view(-1)
    z = F.normalize(embeddings, dim=-1)
    logits = z @ z.T / max(float(temperature), 1.0e-6)
    logits = logits - logits.max(dim=1, keepdim=True).values.detach()
    eye = torch.eye(labels.shape[0], dtype=torch.bool, device=labels.device)
    positive_mask = (labels[:, None] == labels[None, :]) & ~eye
    valid = positive_mask.any(dim=1)
    if not bool(valid.any().detach().cpu()):
        return embeddings.sum() * 0.0
    exp_logits = torch.exp(logits) * (~eye).float()
    log_prob = logits - torch.log(exp_logits.sum(dim=1, keepdim=True).clamp(min=1.0e-12))
    mean_log_prob_pos = (positive_mask.float() * log_prob).sum(dim=1) / positive_mask.float().sum(dim=1).clamp(min=1.0)
    return -mean_log_prob_pos[valid].mean()


def _phenotype_loss_components(
    out: dict[str, torch.Tensor],
    batch: dict[str, torch.Tensor],
    *,
    device: str,
    sample_mask: torch.Tensor | None = None,
    temperature: float = 0.2,
) -> tuple[torch.Tensor, torch.Tensor, float | None]:
    if "logits_phenotype" not in out:
        zero = out["embedding"].sum() * 0.0
        return zero, zero, None
    labels = batch["y_phenotype"].to(device)
    logits = out["logits_phenotype"]
    embeddings = out["embedding"]
    if sample_mask is not None:
        sample_mask = sample_mask.to(device)
        logits = logits[sample_mask]
        embeddings = embeddings[sample_mask]
        labels = labels[sample_mask]
    if labels.numel() <= 0:
        zero = out["embedding"].sum() * 0.0
        return zero, zero, None
    labels = labels.clamp(min=0, max=logits.shape[-1] - 1)
    ce_loss = F.cross_entropy(logits, labels)
    contrastive_loss = _supervised_contrastive_loss(embeddings, labels, temperature=temperature)
    pred = logits.argmax(dim=-1)
    acc = float((pred == labels).float().mean().detach().cpu())
    return ce_loss, contrastive_loss, acc


def _make_loader(
    data: TrajectoryData,
    indices: np.ndarray,
    *,
    batch_size: int,
    shuffle: bool,
    los_mean: float,
    los_std: float,
    include_patient_window: bool = False,
    source_id: int | None = None,
    missingness_aware: bool = False,
    delta_clip_hours: float = 48.0,
    gru_d_imputation: bool = False,
    num_workers: int = 0,
    pin_memory: bool = False,
) -> DataLoader:
    dataset = TrajectoryWindowDataset(
        data,
        indices,
        los_mean=los_mean,
        los_std=los_std,
        include_patient_window=include_patient_window,
        source_id=source_id,
        missingness_aware=missingness_aware,
        delta_clip_hours=delta_clip_hours,
        gru_d_imputation=gru_d_imputation,
    )
    num_workers = max(int(num_workers), 0)
    loader_kwargs: dict[str, Any] = {
        "batch_size": batch_size,
        "shuffle": shuffle,
        "num_workers": num_workers,
        "pin_memory": bool(pin_memory),
    }
    if num_workers > 0:
        loader_kwargs["persistent_workers"] = True
        loader_kwargs["prefetch_factor"] = 2
    return DataLoader(dataset, **loader_kwargs)


def _fit_los_scaler(data: TrajectoryData, train_idx: np.ndarray) -> tuple[float, float]:
    values = np.log1p(np.asarray(data.remaining_los_hours[train_idx], dtype=np.float32).reshape(-1))
    values = values[np.isfinite(values)]
    if len(values) == 0:
        return 0.0, 1.0
    return float(values.mean()), max(float(values.std()), 1.0e-6)


def _binary_auc(y: np.ndarray, p: np.ndarray, mask: np.ndarray | None = None) -> float | None:
    y = np.asarray(y).reshape(-1)
    p = np.asarray(p).reshape(-1)
    valid = np.isfinite(y) & np.isfinite(p)
    if mask is not None:
        valid &= np.asarray(mask).reshape(-1) > 0
    y = y[valid]
    p = p[valid]
    if len(y) == 0 or len(np.unique(y)) < 2:
        return None
    return float(roc_auc_score(y, p))


def _evaluate_auxiliary(
    model: TrajectoryEncoderModel,
    loader: DataLoader,
    *,
    device: str,
    los_mean: float,
    los_std: float,
) -> dict[str, Any]:
    model.eval()
    y_mortality: list[np.ndarray] = []
    p_mortality: list[np.ndarray] = []
    y_sepsis: list[np.ndarray] = []
    p_sepsis: list[np.ndarray] = []
    m_sepsis: list[np.ndarray] = []
    y_los: list[np.ndarray] = []
    p_los: list[np.ndarray] = []
    y_mv: list[np.ndarray] = []
    p_mv: list[np.ndarray] = []
    m_mv: list[np.ndarray] = []
    y_rrt: list[np.ndarray] = []
    p_rrt: list[np.ndarray] = []
    m_rrt: list[np.ndarray] = []
    with torch.no_grad():
        for batch in loader:
            out = _forward_model(model, batch, device=device)
            y_mortality.append(batch["y_mortality"].numpy())
            p_mortality.append(torch.sigmoid(out["logits_mortality"]).cpu().numpy())
            y_sepsis.append(batch["y_sepsis"].numpy())
            p_sepsis.append(torch.sigmoid(out["logits_sepsis"]).cpu().numpy())
            m_sepsis.append(batch["mask_sepsis"].numpy())
            y_los.append(batch["y_los"].numpy())
            p_los.append(out["pred_los"].cpu().numpy())
            y_mv.append(batch["y_next_mv"].numpy())
            p_mv.append(torch.sigmoid(out["logits_next_mv"]).cpu().numpy())
            m_mv.append(batch["mask_next_mv"].numpy())
            y_rrt.append(batch["y_next_rrt"].numpy())
            p_rrt.append(torch.sigmoid(out["logits_next_rrt"]).cpu().numpy())
            m_rrt.append(batch["mask_next_rrt"].numpy())

    y_los_arr = np.concatenate(y_los) * los_std + los_mean
    p_los_arr = np.concatenate(p_los) * los_std + los_mean
    y_los_hours = np.expm1(y_los_arr)
    p_los_hours = np.maximum(np.expm1(p_los_arr), 0.0)

    return {
        "mortality_auroc": _binary_auc(np.concatenate(y_mortality), np.concatenate(p_mortality)),
        "sepsis_auroc": _binary_auc(np.concatenate(y_sepsis), np.concatenate(p_sepsis), np.concatenate(m_sepsis)),
        "sepsis_coverage": float(np.mean(np.concatenate(m_sepsis) > 0)),
        "remaining_los_mae_hours": float(mean_absolute_error(y_los_hours, p_los_hours)),
        "next_mv_auroc": _binary_auc(np.concatenate(y_mv), np.concatenate(p_mv), np.concatenate(m_mv)),
        "next_mv_coverage": float(np.mean(np.concatenate(m_mv) > 0)),
        "next_rrt_auroc": _binary_auc(np.concatenate(y_rrt), np.concatenate(p_rrt), np.concatenate(m_rrt)),
        "next_rrt_coverage": float(np.mean(np.concatenate(m_rrt) > 0)),
    }


def _auxiliary_val_score(metrics: dict[str, Any]) -> float:
    score = 0.0
    if metrics["mortality_auroc"] is not None:
        score += float(metrics["mortality_auroc"])
    if metrics["sepsis_auroc"] is not None:
        score += 0.5 * float(metrics["sepsis_auroc"])
    if metrics["next_mv_auroc"] is not None:
        score += 0.5 * float(metrics["next_mv_auroc"])
    score -= min(float(metrics["remaining_los_mae_hours"]) / 240.0, 1.0)
    return score


@dataclass
class SourceTrainingBundle:
    name: str
    data: TrajectoryData
    splits: dict[str, np.ndarray]
    los_mean: float
    los_std: float
    train_loader: DataLoader
    val_loader: DataLoader
    source_id: int
    is_main: bool = False


def _auxiliary_loss_components(
    out: dict[str, torch.Tensor],
    batch: dict[str, torch.Tensor],
    *,
    device: str,
    lambda_mortality: float,
    lambda_sepsis: float,
    lambda_los: float,
    lambda_next_mv: float,
    lambda_next_rrt: float,
) -> tuple[torch.Tensor, dict[str, torch.Tensor]]:
    loss_mortality = F.binary_cross_entropy_with_logits(
        out["logits_mortality"],
        batch["y_mortality"].to(device),
    )
    loss_sepsis = _masked_bce(
        out["logits_sepsis"],
        batch["y_sepsis"].to(device),
        batch["mask_sepsis"].to(device),
    )
    loss_los = F.smooth_l1_loss(out["pred_los"], batch["y_los"].to(device))
    loss_mv = _masked_bce(
        out["logits_next_mv"],
        batch["y_next_mv"].to(device),
        batch["mask_next_mv"].to(device),
    )
    loss_rrt = _masked_bce(
        out["logits_next_rrt"],
        batch["y_next_rrt"].to(device),
        batch["mask_next_rrt"].to(device),
    )
    weighted = (
        lambda_mortality * loss_mortality
        + lambda_sepsis * loss_sepsis
        + lambda_los * loss_los
        + lambda_next_mv * loss_mv
        + lambda_next_rrt * loss_rrt
    )
    return weighted, {
        "mortality": loss_mortality,
        "sepsis": loss_sepsis,
        "los": loss_los,
        "next_mv": loss_mv,
        "next_rrt": loss_rrt,
    }


def _concat_batches(batches: list[dict[str, torch.Tensor]]) -> dict[str, torch.Tensor]:
    keys = batches[0].keys()
    return {key: torch.cat([batch[key] for batch in batches], dim=0) for key in keys}


def _slice_tensor_dict(values: dict[str, torch.Tensor], mask: torch.Tensor) -> dict[str, torch.Tensor]:
    return {key: value[mask] for key, value in values.items()}


def _next_balanced_batch(
    iterators: list[Any],
    loaders: list[DataLoader],
    source_index: int,
) -> tuple[dict[str, torch.Tensor], list[Any]]:
    try:
        return next(iterators[source_index]), iterators
    except StopIteration:
        iterators[source_index] = iter(loaders[source_index])
        return next(iterators[source_index]), iterators


def _covariance(x: torch.Tensor) -> torch.Tensor:
    if x.shape[0] <= 1:
        return x.new_zeros((x.shape[1], x.shape[1]))
    centered = x - x.mean(dim=0, keepdim=True)
    return centered.T @ centered / float(x.shape[0] - 1)


def _source_coral_loss(embeddings: torch.Tensor, source_ids: torch.Tensor) -> torch.Tensor:
    unique_sources = torch.unique(source_ids)
    if unique_sources.numel() <= 1:
        return embeddings.sum() * 0.0
    losses: list[torch.Tensor] = []
    for i, source_a in enumerate(unique_sources):
        emb_a = embeddings[source_ids == source_a]
        mean_a = emb_a.mean(dim=0)
        cov_a = _covariance(emb_a)
        for source_b in unique_sources[i + 1 :]:
            emb_b = embeddings[source_ids == source_b]
            mean_b = emb_b.mean(dim=0)
            cov_b = _covariance(emb_b)
            losses.append(F.mse_loss(mean_a, mean_b) + F.mse_loss(cov_a, cov_b))
    if not losses:
        return embeddings.sum() * 0.0
    return torch.stack(losses).mean()


def _source_accuracy(logits: torch.Tensor, source_ids: torch.Tensor) -> float:
    if source_ids.numel() == 0:
        return 0.0
    pred = logits.argmax(dim=-1)
    return float((pred == source_ids).float().mean().detach().cpu())


def _evaluate_sources(
    model: TrajectoryEncoderModel,
    bundles: list[SourceTrainingBundle],
    *,
    device: str,
) -> tuple[dict[str, Any], float, float]:
    by_source: dict[str, Any] = {}
    scores: list[float] = []
    for bundle in bundles:
        metrics = _evaluate_auxiliary(
            model,
            bundle.val_loader,
            device=device,
            los_mean=bundle.los_mean,
            los_std=bundle.los_std,
        )
        score = _auxiliary_val_score(metrics)
        by_source[bundle.name] = {
            "source_id": bundle.source_id,
            "is_main": bundle.is_main,
            "val_score": float(score),
            "auxiliary": metrics,
        }
        scores.append(float(score))
    avg_score = float(np.mean(scores)) if scores else float("-inf")
    worst_score = float(np.min(scores)) if scores else float("-inf")
    return by_source, avg_score, worst_score


def _train_source_balanced_auxiliary_stage(
    *,
    model: TrajectoryEncoderModel,
    bundles: list[SourceTrainingBundle],
    output_dir: Path,
    stage_name: str,
    epochs: int,
    steps_per_epoch: int | None,
    lr: float,
    weight_decay: float,
    patience: int,
    lambda_mortality: float,
    lambda_sepsis: float,
    lambda_los: float,
    lambda_next_mv: float,
    lambda_next_rrt: float,
    domain_invariance: str,
    lambda_domain: float,
    domain_grl_lambda: float,
    source_objective: str,
    group_dro_eta: float,
    lambda_phenotype: float,
    lambda_phenotype_contrastive: float,
    phenotype_contrastive_temperature: float,
    device: str,
) -> tuple[list[dict[str, Any]], dict[str, torch.Tensor] | None, float]:
    if epochs <= 0 or not bundles:
        return [], copy.deepcopy(_state_dict_for_save(model)), float("-inf")

    loaders = [bundle.train_loader for bundle in bundles]
    inferred_steps = max(1, min(len(loader) for loader in loaders))
    epoch_steps = int(steps_per_epoch) if steps_per_epoch is not None and steps_per_epoch > 0 else inferred_steps
    base_model = _unwrap_model(model)
    use_adversarial = domain_invariance in {"adversarial", "adversarial_coral"} and base_model.head_source is not None
    use_coral = domain_invariance in {"coral", "adversarial_coral"}
    objective = str(source_objective).replace("-", "_")
    if objective not in {"mean", "group_dro"}:
        raise ValueError("source_objective must be 'mean' or 'group_dro'")

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=weight_decay)
    group_weights = torch.full((len(bundles),), 1.0 / len(bundles), dtype=torch.float32, device=device)
    best_state: dict[str, torch.Tensor] | None = None
    best_score = -np.inf
    stale = 0
    history: list[dict[str, Any]] = []

    for epoch in range(1, epochs + 1):
        started = time.time()
        model.train()
        iterators = [iter(loader) for loader in loaders]
        losses: list[float] = []
        aux_losses: list[float] = []
        domain_losses: list[float] = []
        phenotype_losses: list[float] = []
        phenotype_ce_losses: list[float] = []
        phenotype_contrastive_losses: list[float] = []
        phenotype_accs: list[float] = []
        source_accs: list[float] = []
        coral_losses: list[float] = []
        source_loss_sums = np.zeros(len(bundles), dtype=np.float64)
        source_loss_counts = np.zeros(len(bundles), dtype=np.float64)

        for _step in range(epoch_steps):
            source_batches: list[dict[str, torch.Tensor]] = []
            for source_index, _loader in enumerate(loaders):
                batch, iterators = _next_balanced_batch(iterators, loaders, source_index)
                source_batches.append(batch)
            batch = _concat_batches(source_batches)

            optimizer.zero_grad()
            out = _forward_model(
                model,
                batch,
                device=device,
                grl_lambda=domain_grl_lambda if use_adversarial else 0.0,
            )
            aux_loss, _components = _auxiliary_loss_components(
                out,
                batch,
                device=device,
                lambda_mortality=lambda_mortality,
                lambda_sepsis=lambda_sepsis,
                lambda_los=lambda_los,
                lambda_next_mv=lambda_next_mv,
                lambda_next_rrt=lambda_next_rrt,
            )
            source_ids = batch["source_id"].to(device)
            group_losses: list[torch.Tensor] = []
            for source_index in range(len(bundles)):
                source_mask = source_ids == source_index
                if not bool(source_mask.any().detach().cpu()):
                    group_losses.append(aux_loss.sum() * 0.0)
                    continue
                source_out = _slice_tensor_dict(out, source_mask)
                source_batch = _slice_tensor_dict(batch, source_mask.detach().cpu())
                source_loss, _source_components = _auxiliary_loss_components(
                    source_out,
                    source_batch,
                    device=device,
                    lambda_mortality=lambda_mortality,
                    lambda_sepsis=lambda_sepsis,
                    lambda_los=lambda_los,
                    lambda_next_mv=lambda_next_mv,
                    lambda_next_rrt=lambda_next_rrt,
                )
                group_losses.append(source_loss)
                source_loss_sums[source_index] += float(source_loss.detach().cpu())
                source_loss_counts[source_index] += 1.0
            group_loss_tensor = torch.stack(group_losses)
            if objective == "group_dro":
                with torch.no_grad():
                    group_weights *= torch.exp(float(group_dro_eta) * group_loss_tensor.detach())
                    group_weights /= group_weights.sum().clamp(min=1.0e-12)
                aux_loss = (group_weights.detach() * group_loss_tensor).sum()
            else:
                aux_loss = group_loss_tensor.mean()

            domain_loss = aux_loss.sum() * 0.0
            if use_adversarial:
                source_loss = F.cross_entropy(out["logits_source"], source_ids)
                domain_loss = domain_loss + source_loss
                source_accs.append(_source_accuracy(out["logits_source"], source_ids))
            if use_coral:
                coral_loss = _source_coral_loss(out["embedding"], source_ids)
                domain_loss = domain_loss + coral_loss
                coral_losses.append(float(coral_loss.detach().cpu()))

            phenotype_loss = aux_loss.sum() * 0.0
            if lambda_phenotype > 0 or lambda_phenotype_contrastive > 0:
                phenotype_mask = source_ids == 0
                ce_loss, contrastive_loss, phenotype_acc = _phenotype_loss_components(
                    out,
                    batch,
                    device=device,
                    sample_mask=phenotype_mask,
                    temperature=phenotype_contrastive_temperature,
                )
                phenotype_loss = (
                    float(lambda_phenotype) * ce_loss
                    + float(lambda_phenotype_contrastive) * contrastive_loss
                )
                phenotype_losses.append(float(phenotype_loss.detach().cpu()))
                phenotype_ce_losses.append(float(ce_loss.detach().cpu()))
                phenotype_contrastive_losses.append(float(contrastive_loss.detach().cpu()))
                if phenotype_acc is not None:
                    phenotype_accs.append(phenotype_acc)

            loss = aux_loss + float(lambda_domain) * domain_loss + phenotype_loss
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()

            losses.append(float(loss.detach().cpu()))
            aux_losses.append(float(aux_loss.detach().cpu()))
            domain_losses.append(float(domain_loss.detach().cpu()))

        val_by_source, val_avg_score, val_worst_score = _evaluate_sources(model, bundles, device=device)
        val_score = val_worst_score if objective == "group_dro" else val_avg_score
        mean_source_losses = np.divide(
            source_loss_sums,
            np.maximum(source_loss_counts, 1.0),
            out=np.zeros_like(source_loss_sums),
            where=source_loss_counts > 0,
        )
        history.append(
            {
                "stage": stage_name,
                "epoch": epoch,
                "time_s": round(time.time() - started, 2),
                "train_loss": round(float(np.mean(losses)), 5) if losses else 0.0,
                "train_auxiliary_loss": round(float(np.mean(aux_losses)), 5) if aux_losses else 0.0,
                "train_domain_loss": round(float(np.mean(domain_losses)), 5) if domain_losses else 0.0,
                "train_phenotype_loss": round(float(np.mean(phenotype_losses)), 5) if phenotype_losses else None,
                "train_phenotype_ce_loss": round(float(np.mean(phenotype_ce_losses)), 5) if phenotype_ce_losses else None,
                "train_phenotype_contrastive_loss": round(float(np.mean(phenotype_contrastive_losses)), 5) if phenotype_contrastive_losses else None,
                "train_phenotype_accuracy": round(float(np.mean(phenotype_accs)), 5) if phenotype_accs else None,
                "train_source_accuracy": round(float(np.mean(source_accs)), 5) if source_accs else None,
                "train_coral_loss": round(float(np.mean(coral_losses)), 5) if coral_losses else None,
                "train_source_losses": {
                    bundle.name: round(float(mean_source_losses[bundle.source_id]), 5) for bundle in bundles
                },
                "group_dro_weights": {
                    bundle.name: round(float(group_weights[bundle.source_id].detach().cpu()), 5)
                    for bundle in bundles
                },
                "val_score": round(float(val_score), 5),
                "val_avg_score": round(float(val_avg_score), 5),
                "val_worst_score": round(float(val_worst_score), 5),
                "val_by_source": val_by_source,
                "balanced_steps_per_epoch": epoch_steps,
                "n_sources": len(bundles),
                "domain_invariance": domain_invariance,
                "lambda_domain": float(lambda_domain),
                "lambda_phenotype": float(lambda_phenotype),
                "lambda_phenotype_contrastive": float(lambda_phenotype_contrastive),
                "phenotype_contrastive_temperature": float(phenotype_contrastive_temperature),
                "source_objective": objective,
                "group_dro_eta": float(group_dro_eta),
            }
        )
        if val_score > best_score:
            best_score = float(val_score)
            best_state = copy.deepcopy(_state_dict_for_save(model))
            stale = 0
            torch.save(
                {"model_state_dict": best_state, "stage": stage_name, "val_score": best_score},
                output_dir / "checkpoints" / f"trajectory_encoder_{stage_name}_best.pt",
            )
        else:
            stale += 1
            if stale >= patience:
                break

    if best_state is not None:
        _load_model_state(model, best_state)
    return history, best_state, best_score


def _train_auxiliary_stage(
    *,
    model: TrajectoryEncoderModel,
    train_loader: DataLoader,
    val_loader: DataLoader,
    output_dir: Path,
    stage_name: str,
    epochs: int,
    lr: float,
    weight_decay: float,
    patience: int,
    lambda_mortality: float,
    lambda_sepsis: float,
    lambda_los: float,
    lambda_next_mv: float,
    lambda_next_rrt: float,
    lambda_phenotype: float,
    lambda_phenotype_contrastive: float,
    phenotype_contrastive_temperature: float,
    los_mean: float,
    los_std: float,
    device: str,
) -> tuple[list[dict[str, Any]], dict[str, torch.Tensor] | None, float]:
    if epochs <= 0:
        return [], copy.deepcopy(_state_dict_for_save(model)), float("-inf")

    optimizer = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=weight_decay)
    best_state: dict[str, torch.Tensor] | None = None
    best_score = -np.inf
    stale = 0
    history: list[dict[str, Any]] = []

    for epoch in range(1, epochs + 1):
        started = time.time()
        model.train()
        losses: list[float] = []
        phenotype_losses: list[float] = []
        phenotype_accs: list[float] = []
        for batch in train_loader:
            optimizer.zero_grad()
            out = _forward_model(model, batch, device=device)
            loss_mortality = F.binary_cross_entropy_with_logits(
                out["logits_mortality"],
                batch["y_mortality"].to(device),
            )
            loss_sepsis = _masked_bce(
                out["logits_sepsis"],
                batch["y_sepsis"].to(device),
                batch["mask_sepsis"].to(device),
            )
            loss_los = F.smooth_l1_loss(out["pred_los"], batch["y_los"].to(device))
            loss_mv = _masked_bce(
                out["logits_next_mv"],
                batch["y_next_mv"].to(device),
                batch["mask_next_mv"].to(device),
            )
            loss_rrt = _masked_bce(
                out["logits_next_rrt"],
                batch["y_next_rrt"].to(device),
                batch["mask_next_rrt"].to(device),
            )
            loss = (
                lambda_mortality * loss_mortality
                + lambda_sepsis * loss_sepsis
                + lambda_los * loss_los
                + lambda_next_mv * loss_mv
                + lambda_next_rrt * loss_rrt
            )
            if lambda_phenotype > 0 or lambda_phenotype_contrastive > 0:
                ce_loss, contrastive_loss, phenotype_acc = _phenotype_loss_components(
                    out,
                    batch,
                    device=device,
                    temperature=phenotype_contrastive_temperature,
                )
                phenotype_loss = (
                    float(lambda_phenotype) * ce_loss
                    + float(lambda_phenotype_contrastive) * contrastive_loss
                )
                loss = loss + phenotype_loss
                phenotype_losses.append(float(phenotype_loss.detach().cpu()))
                if phenotype_acc is not None:
                    phenotype_accs.append(phenotype_acc)
            loss.backward()
            nn.utils.clip_grad_norm_(model.parameters(), max_norm=5.0)
            optimizer.step()
            losses.append(float(loss.detach().cpu()))

        val_aux = _evaluate_auxiliary(model, val_loader, device=device, los_mean=los_mean, los_std=los_std)
        val_score = _auxiliary_val_score(val_aux)
        history.append(
            {
                "stage": stage_name,
                "epoch": epoch,
                "time_s": round(time.time() - started, 2),
                "train_loss": round(float(np.mean(losses)), 5) if losses else 0.0,
                "train_phenotype_loss": round(float(np.mean(phenotype_losses)), 5) if phenotype_losses else None,
                "train_phenotype_accuracy": round(float(np.mean(phenotype_accs)), 5) if phenotype_accs else None,
                "val_score": round(float(val_score), 5),
                "val_auxiliary": val_aux,
            }
        )
        if val_score > best_score:
            best_score = float(val_score)
            best_state = copy.deepcopy(_state_dict_for_save(model))
            stale = 0
            torch.save(
                {"model_state_dict": best_state, "stage": stage_name, "val_score": best_score},
                output_dir / "checkpoints" / f"trajectory_encoder_{stage_name}_best.pt",
            )
        else:
            stale += 1
            if stale >= patience:
                break

    if best_state is not None:
        _load_model_state(model, best_state)
    return history, best_state, best_score


def fit_transition_matrix(
    labels: np.ndarray,
    train_idx: np.ndarray,
    *,
    n_classes: int,
    alpha: float = 1.0,
) -> tuple[np.ndarray, np.ndarray]:
    counts = np.full((n_classes, n_classes), float(alpha), dtype=np.float64)
    initial = np.full(n_classes, float(alpha), dtype=np.float64)
    train_labels = labels[train_idx]
    for row in train_labels:
        initial[int(row[0])] += 1.0
        for a, b in zip(row[:-1], row[1:]):
            counts[int(a), int(b)] += 1.0
    row_sums = counts.sum(axis=1, keepdims=True)
    trans = np.zeros_like(counts)
    np.divide(counts, row_sums, out=trans, where=row_sums > 0)
    for state in range(n_classes):
        if row_sums[state, 0] <= 0:
            trans[state, state] = 1.0
    init_sum = float(initial.sum())
    init = initial / init_sum if init_sum > 0 else np.full(n_classes, 1.0 / n_classes, dtype=np.float64)
    return init, trans


def viterbi_smooth(
    emissions: np.ndarray,
    init_probs: np.ndarray,
    transition_probs: np.ndarray,
    *,
    emission_weight: float = 1.0,
    transition_weight: float = 1.0,
) -> np.ndarray:
    emissions = np.asarray(emissions, dtype=np.float64)
    n_patients, n_windows, n_classes = emissions.shape
    eps = 1.0e-12
    log_emit = np.log(np.clip(emissions, eps, 1.0)) * float(emission_weight)
    log_init = np.log(np.clip(init_probs, eps, 1.0))
    log_trans = np.log(np.clip(transition_probs, eps, 1.0)) * float(transition_weight)
    out = np.zeros((n_patients, n_windows), dtype=np.int64)
    for i in range(n_patients):
        dp = np.zeros((n_windows, n_classes), dtype=np.float64)
        back = np.zeros((n_windows, n_classes), dtype=np.int64)
        dp[0] = log_init + log_emit[i, 0]
        for t in range(1, n_windows):
            scores = dp[t - 1][:, None] + log_trans
            back[t] = np.argmax(scores, axis=0)
            dp[t] = scores[back[t], np.arange(n_classes)] + log_emit[i, t]
        out[i, -1] = int(np.argmax(dp[-1]))
        for t in range(n_windows - 2, -1, -1):
            out[i, t] = back[t + 1, out[i, t + 1]]
    return out


def _metrics_for_predictions(y_true: np.ndarray, y_pred: np.ndarray) -> dict[str, Any]:
    y_true = np.asarray(y_true, dtype=np.int64)
    y_pred = np.asarray(y_pred, dtype=np.int64)
    match = y_true == y_pred
    patient_match = match.mean(axis=1)
    return {
        "window_match_rate": float(match.mean()),
        "mean_patient_match_rate": float(patient_match.mean()),
        "full_patient_match_rate": float((patient_match == 1.0).mean()),
        "zero_match_patient_rate": float((patient_match == 0.0).mean()),
        "macro_f1": float(f1_score(y_true.reshape(-1), y_pred.reshape(-1), average="macro", zero_division=0)),
        "per_window_match_rate": [float(match[:, wi].mean()) for wi in range(match.shape[1])],
    }


def _score_rule_values(
    *,
    age: float,
    hr: float,
    map_val: float,
    resp: float,
    spo2: float,
    temp: float,
    lactate: float,
    creatinine: float,
    wbc: float,
) -> np.ndarray:
    p0 = 50.0
    if 60 <= hr <= 90:
        p0 += 15
    if 70 <= map_val <= 105:
        p0 += 15
    if 12 <= resp <= 20:
        p0 += 10
    if spo2 >= 95:
        p0 += 10
    if 36 <= temp <= 37.5:
        p0 += 10
    if lactate <= 2:
        p0 += 10
    if creatinine <= 1.2:
        p0 += 10
    if age < 65:
        p0 += 10

    p1 = 30.0
    if 90 < hr <= 110 or hr < 60:
        p1 += 15
    if 65 <= map_val < 70:
        p1 += 15
    if 20 < resp <= 28 or temp > 38:
        p1 += 15
    if 90 <= spo2 < 95:
        p1 += 10
    if 2 < lactate <= 4:
        p1 += 15
    if 1.2 < creatinine <= 2:
        p1 += 10
    if wbc > 12 or wbc < 4:
        p1 += 10

    p2 = 20.0
    if hr > 110 or hr < 50:
        p2 += 15
    if map_val < 65:
        p2 += 25
    if resp > 28:
        p2 += 15
    if spo2 < 90:
        p2 += 20
    if temp > 39 or temp < 35:
        p2 += 10
    if lactate > 4:
        p2 += 20
    if creatinine > 2:
        p2 += 15
    if age > 75:
        p2 += 10

    p3 = 35.0
    if 70 <= hr <= 100:
        p3 += 10
    if 65 <= map_val <= 90:
        p3 += 15
    if 18 <= resp <= 24:
        p3 += 10
    if spo2 >= 92:
        p3 += 15
    if 2 < lactate <= 4:
        p3 += 15
    if 1.5 < creatinine <= 2.5:
        p3 += 10
    if age > 60:
        p3 += 10

    return np.asarray([min(p0, 100.0), min(p1, 100.0), min(p2, 100.0), min(p3, 100.0)], dtype=np.float64)


def _softmax(values: np.ndarray, temperature: float) -> np.ndarray:
    z = np.asarray(values, dtype=np.float64) / max(float(temperature), 1.0e-6)
    z = z - z.max(axis=-1, keepdims=True)
    exp = np.exp(z)
    return exp / exp.sum(axis=-1, keepdims=True)


def _window_mean_raw(
    raw: np.ndarray,
    mask: np.ndarray,
    *,
    feature_idx: int | None,
    start: int,
    end: int,
    fallback: float,
) -> float:
    if feature_idx is None:
        return float(fallback)
    values = np.asarray(raw[start:end, feature_idx], dtype=np.float64)
    obs = (np.asarray(mask[start:end, feature_idx]) > 0) & np.isfinite(values)
    if obs.any():
        return float(values[obs].mean())
    return float(fallback)


def compute_rule_probabilities(
    data: TrajectoryData,
    *,
    temperature: float = 12.0,
    patient_indices: np.ndarray | None = None,
) -> np.ndarray:
    """Compute current webapp-style rule emissions for all patient windows."""
    if patient_indices is None:
        patient_indices = np.arange(data.n_patients, dtype=np.int64)
    else:
        patient_indices = np.asarray(patient_indices, dtype=np.int64)
    n_patients = int(len(patient_indices))
    n_windows = data.n_windows
    n_classes = max(data.n_classes, 4)
    probs = np.zeros((n_patients, n_windows, n_classes), dtype=np.float32)
    idx = {name: _find_feature(data.feature_names, name) for name in FEATURE_ALIASES}
    fallback = {
        name: float(data.feature_medians[i]) if i is not None and i < len(data.feature_medians) else 0.0
        for name, i in idx.items()
    }
    for out_i, pi in enumerate(patient_indices):
        raw = np.asarray(data.raw_continuous[pi])
        mask = np.asarray(data.raw_masks_continuous[pi])
        age = pd.to_numeric(pd.Series([data.static.iloc[pi].get("age", 60.0)]), errors="coerce").fillna(60.0).iloc[0]
        for wi, start in enumerate(data.window_starts):
            end = min(int(start) + int(data.window_len), raw.shape[0])
            hr = _window_mean_raw(raw, mask, feature_idx=idx["heart_rate"], start=start, end=end, fallback=fallback["heart_rate"])
            sbp = _window_mean_raw(raw, mask, feature_idx=idx["sbp"], start=start, end=end, fallback=fallback["sbp"])
            dbp = _window_mean_raw(raw, mask, feature_idx=idx["dbp"], start=start, end=end, fallback=fallback["dbp"])
            map_val = _window_mean_raw(raw, mask, feature_idx=idx["map"], start=start, end=end, fallback=fallback["map"])
            if map_val == 0.0:
                map_val = (sbp + 2.0 * dbp) / 3.0
            scores = _score_rule_values(
                age=float(age),
                hr=hr,
                map_val=map_val,
                resp=_window_mean_raw(raw, mask, feature_idx=idx["resp_rate"], start=start, end=end, fallback=fallback["resp_rate"]),
                spo2=_window_mean_raw(raw, mask, feature_idx=idx["spo2"], start=start, end=end, fallback=fallback["spo2"]),
                temp=_window_mean_raw(raw, mask, feature_idx=idx["temperature"], start=start, end=end, fallback=fallback["temperature"]),
                lactate=_window_mean_raw(raw, mask, feature_idx=idx["lactate"], start=start, end=end, fallback=fallback["lactate"]),
                creatinine=_window_mean_raw(raw, mask, feature_idx=idx["creatinine"], start=start, end=end, fallback=fallback["creatinine"]),
                wbc=_window_mean_raw(raw, mask, feature_idx=idx["wbc"], start=start, end=end, fallback=fallback["wbc"]),
            )
            p4 = _softmax(scores, temperature=temperature)
            probs[out_i, wi, :4] = p4.astype(np.float32)
            if n_classes > 4:
                probs[out_i, wi, 4:] = 1.0e-6
                probs[out_i, wi] /= probs[out_i, wi].sum()
    return probs[:, :, : data.n_classes]


def _extract_embeddings(
    model: TrajectoryEncoderModel,
    loader: DataLoader,
    *,
    device: str,
    n_classes: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:
    model.eval()
    embeddings: list[np.ndarray] = []
    labels: list[np.ndarray] = []
    windows: list[np.ndarray] = []
    patients: list[np.ndarray] = []
    with torch.no_grad():
        for batch in loader:
            if getattr(model, "use_gru_d", False):
                emb = model.encode_gru_d(
                    batch["x_obs_cont"].to(device),
                    batch["m_cont"].to(device),
                    batch["delta_cont"].to(device),
                    batch["x_locf_cont"].to(device),
                    batch["side_feats"].to(device),
                    batch["length"].to(device),
                )
            else:
                emb = model.encode(batch["x"].to(device), batch["length"].to(device))
            embeddings.append(emb.cpu().numpy())
            labels.append(batch["y_phenotype"].numpy())
            windows.append(batch["window_idx"].numpy())
            patients.append(batch["patient_idx"].numpy())
    y = np.concatenate(labels).astype(np.int64)
    y = np.clip(y, 0, n_classes - 1)
    return np.concatenate(embeddings), y, np.concatenate(windows), np.concatenate(patients)


def _augment_embeddings_with_window(emb: np.ndarray, window_idx: np.ndarray, n_windows: int) -> np.ndarray:
    one_hot = np.zeros((len(window_idx), n_windows), dtype=np.float32)
    one_hot[np.arange(len(window_idx)), window_idx.astype(int)] = 1.0
    return np.concatenate([emb, one_hot], axis=1)


def _readout_probs_by_patient(
    clf: Any,
    emb: np.ndarray,
    windows: np.ndarray,
    patients: np.ndarray,
    patient_indices: np.ndarray,
    *,
    n_windows: int,
    n_classes: int,
) -> np.ndarray:
    probs_flat = clf.predict_proba(_augment_embeddings_with_window(emb, windows, n_windows))
    full = np.zeros((len(probs_flat), n_classes), dtype=np.float32)
    for col, cls in enumerate(clf.classes_):
        full[:, int(cls)] = probs_flat[:, col]
    missing = full.sum(axis=1) <= 0
    if missing.any():
        full[missing] = 1.0 / n_classes

    pos = {int(patient): row for row, patient in enumerate(patient_indices)}
    out = np.zeros((len(patient_indices), n_windows, n_classes), dtype=np.float32)
    for prob, patient, window in zip(full, patients, windows):
        out[pos[int(patient)], int(window)] = prob
    empty = out.sum(axis=-1) <= 0
    if empty.any():
        out[empty] = 1.0 / n_classes
    return out


def _export_existing_consistency(s0_dir: Path) -> dict[str, Any] | None:
    path = Path(s0_dir) / "prediction_consistency_labels.csv"
    if not path.exists():
        return None
    df = pd.read_csv(path)
    if "match_rate" not in df.columns:
        return None
    return {
        "source": str(path),
        "patients": int(len(df)),
        "mean_patient_match_rate": float(df["match_rate"].mean()),
        "full_patient_match_rate": float((df["match_rate"] == 1.0).mean()),
        "zero_match_patient_rate": float((df["match_rate"] == 0.0).mean()),
    }


def _load_kmeans_centers(path: Path) -> np.ndarray:
    model = _read_json(path)
    centers = model.get("centers", model.get("cluster_centers"))
    if centers is None:
        raise ValueError(f"kmeans centers not found in {path}")
    return np.asarray(centers, dtype=np.float64)


def align_labels_by_kmeans_centers(
    labels: np.ndarray,
    *,
    source_kmeans_path: Path,
    reference_kmeans_path: Path,
) -> tuple[np.ndarray, dict[str, Any]]:
    """Map source cluster IDs onto reference IDs by centroid cosine distance.

    This is an unsupervised label-ID alignment step for external validation.
    It does not use outcomes, predictions, or held-out correctness.
    """
    source_centers = _load_kmeans_centers(Path(source_kmeans_path))
    reference_centers = _load_kmeans_centers(Path(reference_kmeans_path))
    if source_centers.shape != reference_centers.shape:
        raise ValueError(
            f"kmeans center shape mismatch: source={source_centers.shape}, "
            f"reference={reference_centers.shape}"
        )
    source_norm = source_centers / np.maximum(np.linalg.norm(source_centers, axis=1, keepdims=True), 1.0e-12)
    reference_norm = reference_centers / np.maximum(np.linalg.norm(reference_centers, axis=1, keepdims=True), 1.0e-12)
    cosine_similarity = source_norm @ reference_norm.T
    cost = 1.0 - cosine_similarity
    rows, cols = linear_sum_assignment(cost)
    mapping = {int(row): int(col) for row, col in zip(rows, cols)}
    aligned = np.vectorize(lambda value: mapping.get(int(value), int(value)), otypes=[np.int64])(labels)
    assigned_costs = [float(cost[row, col]) for row, col in zip(rows, cols)]
    return aligned.astype(np.int64, copy=False), {
        "method": "kmeans_centroid_cosine_hungarian",
        "source_kmeans_path": str(source_kmeans_path),
        "reference_kmeans_path": str(reference_kmeans_path),
        "source_to_reference": {str(k): int(v) for k, v in sorted(mapping.items())},
        "mean_cosine_distance": float(np.mean(assigned_costs)),
        "max_cosine_distance": float(np.max(assigned_costs)),
        "assignments": [
            {
                "source": int(row),
                "reference": int(col),
                "cosine_similarity": float(cosine_similarity[row, col]),
                "cosine_distance": float(cost[row, col]),
            }
            for row, col in zip(rows, cols)
        ],
    }


def evaluate_trajectory_encoder(
    *,
    s0_dir: Path,
    s2_dir: Path,
    model_path: Path,
    readout_path: Path,
    output_dir: Path,
    source_name: str,
    reference_kmeans_path: Path | None = None,
    source_kmeans_path: Path | None = None,
    batch_size: int = 512,
    transition_weight: float = 1.0,
    rule_temperature: float = 12.0,
    seed: int = 42,
    device: str = "cpu",
    max_patients: int | None = None,
) -> dict[str, Any]:
    """Evaluate a fixed trajectory encoder/readout on an external bundle."""
    data = load_trajectory_data(s0_dir=Path(s0_dir), s2_dir=Path(s2_dir), seed=seed)
    label_alignment: dict[str, Any] = {"method": "identity"}
    if reference_kmeans_path is not None and source_kmeans_path is not None:
        aligned_labels, label_alignment = align_labels_by_kmeans_centers(
            data.phenotype_labels,
            source_kmeans_path=Path(source_kmeans_path),
            reference_kmeans_path=Path(reference_kmeans_path),
        )
        data.phenotype_labels = aligned_labels

    patient_idx = np.arange(data.n_patients, dtype=np.int64)
    if max_patients is not None:
        patient_idx = patient_idx[: int(max_patients)]

    checkpoint = torch.load(Path(model_path), map_location=device, weights_only=False)
    config = dict(checkpoint.get("config", {}))
    missingness_aware = bool(config.get("missingness_aware", False))
    delta_clip_hours = float(config.get("delta_clip_hours", 48.0))
    use_gru_d = bool(config.get("gru_d_imputation", False))
    expected_input_dim = _model_input_dim(data, missingness_aware=missingness_aware)
    input_dim = int(config.get("input_dim", expected_input_dim))
    if not use_gru_d and input_dim != expected_input_dim:
        raise ValueError(f"model input_dim={input_dim} does not match external input_dim={expected_input_dim}")
    model_kwargs = dict(
        input_dim=input_dim,
        hidden_dim=int(config.get("hidden_dim", 64)),
        embedding_dim=int(config.get("embedding_dim", 64)),
        recurrent=str(config.get("recurrent", "gru")),
        num_layers=int(config.get("num_layers", 1)),
        dropout=float(config.get("dropout", 0.1)),
    )
    if use_gru_d:
        from s6.grud_cell import feature_groups_from_dict

        n_continuous = int(config.get("gru_d_n_continuous", data.continuous.shape[-1]))
        side_dim = int(
            config.get(
                "gru_d_side_dim",
                int(data.proxy_indicators.shape[-1])
                + int(data.interventions.shape[-1])
                + int(data.masks_interventions.shape[-1])
                + (int(data.masks_interventions.shape[-1]) if missingness_aware else 0),
            )
        )
        groups, _ = feature_groups_from_dict(Path(s0_dir) / "feature_dict.json", data.feature_names)
        model_kwargs.update(
            use_gru_d=True,
            gru_d_n_continuous=n_continuous,
            gru_d_side_dim=side_dim,
            gru_d_feature_groups=groups[:n_continuous],
            gru_d_feature_means=np.asarray(data.feature_medians[:n_continuous], dtype=np.float32),
        )
    model = TrajectoryEncoderModel(**model_kwargs).to(device)
    model.load_state_dict(checkpoint["model_state_dict"], strict=False)
    model.eval()

    with open(Path(readout_path), "rb") as f:
        readout = pickle.load(f)

    init_probs = np.asarray(checkpoint["transition_init_probs"], dtype=np.float64)
    transition_probs = np.asarray(checkpoint["transition_probs"], dtype=np.float64)
    los_mean = float(checkpoint.get("los_mean", 0.0))
    los_std = float(checkpoint.get("los_std", 1.0))

    eval_loader = _make_loader(
        data,
        patient_idx,
        batch_size=batch_size,
        shuffle=False,
        los_mean=los_mean,
        los_std=los_std,
        include_patient_window=True,
        missingness_aware=missingness_aware,
        delta_clip_hours=delta_clip_hours,
        gru_d_imputation=use_gru_d,
    )
    emb, y_flat, windows, patients = _extract_embeddings(model, eval_loader, device=device, n_classes=data.n_classes)
    encoder_probs = _readout_probs_by_patient(
        readout,
        emb,
        windows,
        patients,
        patient_idx,
        n_windows=data.n_windows,
        n_classes=data.n_classes,
    )
    encoder_pred = encoder_probs.argmax(axis=-1)
    encoder_smooth = viterbi_smooth(
        encoder_probs,
        init_probs,
        transition_probs,
        transition_weight=transition_weight,
    )

    rule_probs = compute_rule_probabilities(data, temperature=rule_temperature, patient_indices=patient_idx)
    rule_pred = rule_probs.argmax(axis=-1)
    rule_smooth = viterbi_smooth(
        rule_probs,
        init_probs,
        transition_probs,
        transition_weight=transition_weight,
    )
    y_true = data.phenotype_labels[patient_idx]

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    report = {
        "experiment": "s6_trajectory_encoder_external_validation",
        "generated_at": pd.Timestamp.now().isoformat(timespec="seconds"),
        "source": str(source_name),
        "data": {
            "s0_dir": str(Path(s0_dir)),
            "s2_dir": str(Path(s2_dir)),
            "n_patients_total": data.n_patients,
            "n_patients_evaluated": int(len(patient_idx)),
            "n_windows": data.n_windows,
            "n_classes": data.n_classes,
            "window_starts": data.window_starts,
            "window_len": data.window_len,
            "stride": data.stride,
            "base_input_dim": data.input_dim,
            "input_dim": input_dim,
            "missingness_aware": bool(missingness_aware),
            "delta_clip_hours": float(delta_clip_hours),
            "next_mv_coverage": float(np.mean(data.next_mv_masks[patient_idx] > 0)),
            "next_rrt_coverage": float(np.mean(data.next_rrt_masks[patient_idx] > 0)),
        },
        "fixed_artifacts": {
            "model_path": str(Path(model_path)),
            "readout_path": str(Path(readout_path)),
            "transition_source": "checkpoint_train_only_transition_matrix",
        },
        "leakage_guard": {
            "external_refit_encoder": False,
            "external_refit_readout": False,
            "external_refit_transition": False,
            "external_outcomes_used_for_label_alignment": False,
            "external_predictions_used_for_label_alignment": False,
            "label_alignment": label_alignment,
        },
        "metrics": {
            "raw_rule": _metrics_for_predictions(y_true, rule_pred),
            "rule_plus_reference_transition_smoothing": _metrics_for_predictions(y_true, rule_smooth),
            "encoder_readout": _metrics_for_predictions(y_true, encoder_pred),
            "encoder_plus_reference_transition_smoothing": _metrics_for_predictions(y_true, encoder_smooth),
        },
        "auxiliary": _evaluate_auxiliary(
            model,
            eval_loader,
            device=device,
            los_mean=los_mean,
            los_std=los_std,
        ),
        "outputs": {
            "report": str(output_dir / "external_validation_report.json"),
        },
    }
    with open(output_dir / "external_validation_report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    return report


def train_trajectory_encoder(
    *,
    s0_dir: Path,
    s2_dir: Path,
    output_dir: Path,
    splits_path: Path | None = None,
    aux_s0_dir: Path | None = None,
    aux_splits_path: Path | None = None,
    aux_sources: list[dict[str, Path | str | None]] | None = None,
    aux_epochs: int = 0,
    aux_patience: int = 2,
    aux_training_mode: str = "sequential",
    balanced_include_main_source: bool = True,
    balanced_steps_per_epoch: int | None = None,
    domain_invariance: str = "none",
    lambda_domain: float = 0.1,
    domain_grl_lambda: float = 1.0,
    source_objective: str = "mean",
    group_dro_eta: float = 0.05,
    missingness_aware: bool = False,
    delta_clip_hours: float = 48.0,
    gru_d_imputation: bool = False,
    recurrent: str = "gru",
    hidden_dim: int = 64,
    embedding_dim: int = 64,
    num_layers: int = 1,
    dropout: float = 0.1,
    batch_size: int = 128,
    epochs: int = 8,
    lr: float = 1.0e-3,
    weight_decay: float = 1.0e-4,
    patience: int = 3,
    lambda_mortality: float = 1.0,
    lambda_sepsis: float = 1.0,
    lambda_los: float = 0.5,
    lambda_next_mv: float = 0.5,
    lambda_next_rrt: float = 0.5,
    lambda_phenotype: float = 0.0,
    lambda_phenotype_contrastive: float = 0.0,
    phenotype_contrastive_temperature: float = 0.2,
    transition_alpha: float = 1.0,
    transition_weight: float = 1.0,
    rule_temperature: float = 12.0,
    seed: int = 42,
    device: str = "cpu",
    num_workers: int = 0,
    pin_memory: bool | None = None,
    max_train_patients: int | None = None,
    max_eval_patients: int | None = None,
    max_aux_train_patients: int | None = None,
    max_aux_eval_patients: int | None = None,
) -> dict[str, Any]:
    torch.manual_seed(seed)
    np.random.seed(seed)
    data = load_trajectory_data(s0_dir=Path(s0_dir), s2_dir=Path(s2_dir), splits_path=splits_path, seed=seed)
    if pin_memory is None:
        pin_memory = str(device).startswith("cuda")

    splits = {name: values.copy() for name, values in data.splits.items()}
    if max_train_patients is not None:
        splits["train"] = splits["train"][: int(max_train_patients)]
    if max_eval_patients is not None:
        splits["val"] = splits["val"][: int(max_eval_patients)]
        splits["test"] = splits["test"][: int(max_eval_patients)]

    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "checkpoints").mkdir(parents=True, exist_ok=True)

    los_mean, los_std = _fit_los_scaler(data, splits["train"])
    train_loader = _make_loader(
        data,
        splits["train"],
        batch_size=batch_size,
        shuffle=True,
        los_mean=los_mean,
        los_std=los_std,
        missingness_aware=missingness_aware,
        delta_clip_hours=delta_clip_hours,
        gru_d_imputation=gru_d_imputation,
        num_workers=num_workers,
        pin_memory=bool(pin_memory),
    )
    val_loader = _make_loader(
        data,
        splits["val"],
        batch_size=batch_size,
        shuffle=False,
        los_mean=los_mean,
        los_std=los_std,
        missingness_aware=missingness_aware,
        delta_clip_hours=delta_clip_hours,
        gru_d_imputation=gru_d_imputation,
        num_workers=num_workers,
        pin_memory=bool(pin_memory),
    )

    normalized_aux_sources: list[dict[str, Path | str | None]] = []
    if aux_sources:
        normalized_aux_sources.extend(aux_sources)
    elif aux_s0_dir is not None:
        normalized_aux_sources.append({"name": "aux", "s0_dir": Path(aux_s0_dir), "splits_path": aux_splits_path})

    aux_mode = str(aux_training_mode).replace("-", "_")
    if aux_mode not in {"sequential", "source_balanced"}:
        raise ValueError("aux_training_mode must be 'sequential' or 'source_balanced'")
    domain_mode = str(domain_invariance).replace("-", "_")
    if domain_mode not in {"none", "adversarial", "coral", "adversarial_coral"}:
        raise ValueError("domain_invariance must be one of: none, adversarial, coral, adversarial_coral")
    objective_mode = str(source_objective).replace("-", "_")
    if objective_mode not in {"mean", "group_dro"}:
        raise ValueError("source_objective must be 'mean' or 'group-dro'")

    balanced_source_count = len(normalized_aux_sources) + (1 if balanced_include_main_source else 0)
    n_source_head = balanced_source_count if aux_mode == "source_balanced" and domain_mode in {"adversarial", "adversarial_coral"} else 0
    input_dim = _model_input_dim(data, missingness_aware=missingness_aware)
    n_continuous_features = int(data.continuous.shape[-1])
    side_dim = (
        int(data.proxy_indicators.shape[-1])
        + int(data.interventions.shape[-1])
        + int(data.masks_interventions.shape[-1])
        + (int(data.masks_interventions.shape[-1]) if missingness_aware else 0)
    )
    model_kwargs: dict[str, Any] = dict(
        input_dim=input_dim,
        hidden_dim=hidden_dim,
        embedding_dim=embedding_dim,
        recurrent=recurrent,
        num_layers=num_layers,
        dropout=dropout,
        n_sources=n_source_head,
        n_phenotype_classes=data.n_classes if (lambda_phenotype > 0 or lambda_phenotype_contrastive > 0) else 0,
    )
    if gru_d_imputation:
        from s6.grud_cell import feature_groups_from_dict

        groups, _group_indices = feature_groups_from_dict(
            Path(s0_dir) / "feature_dict.json",
            data.feature_names,
        )
        model_kwargs.update(
            use_gru_d=True,
            gru_d_n_continuous=n_continuous_features,
            gru_d_side_dim=side_dim,
            gru_d_feature_groups=groups[:n_continuous_features],
            gru_d_feature_means=np.asarray(
                data.feature_medians[:n_continuous_features], dtype=np.float32
            ),
        )
    model = TrajectoryEncoderModel(**model_kwargs).to(device)
    train_model, data_parallel_gpus = _maybe_wrap_data_parallel(model, device)
    aux_data = None
    aux_splits: dict[str, np.ndarray] | None = None
    aux_los_mean = 0.0
    aux_los_std = 1.0
    aux_history: list[dict[str, Any]] = []
    aux_stage_summaries: list[dict[str, Any]] = []
    balanced_stage_summaries: list[dict[str, Any]] = []

    def _source_summary(
        *,
        name: str,
        source_s0_dir: Path,
        source_data: TrajectoryData,
        source_splits: dict[str, np.ndarray],
        source_los_mean: float,
        source_los_std: float,
        source_id: int | None,
        epochs_trained: int,
        is_main: bool,
    ) -> dict[str, Any]:
        return {
            "name": name,
            "source_id": source_id,
            "is_main": is_main,
            "s0_dir": str(Path(source_s0_dir)),
            "n_patients": source_data.n_patients,
            "split_sizes": {split_name: int(len(values)) for split_name, values in source_splits.items()},
            "next_mv_coverage": float(np.mean(source_data.next_mv_masks[source_splits["train"]] > 0)),
            "next_rrt_coverage": float(np.mean(source_data.next_rrt_masks[source_splits["train"]] > 0)),
            "sepsis_label_coverage": float(np.mean(source_data.sepsis_masks[source_splits["train"]] > 0)),
            "epochs_trained": epochs_trained,
            "los_mean_log1p_train": source_los_mean,
            "los_std_log1p_train": source_los_std,
        }

    if aux_mode == "source_balanced" and aux_epochs > 0 and normalized_aux_sources:
        bundles: list[SourceTrainingBundle] = []
        if balanced_include_main_source:
            main_source_id = len(bundles)
            bundles.append(
                SourceTrainingBundle(
                    name="s0",
                    data=data,
                    splits=splits,
                    los_mean=los_mean,
                    los_std=los_std,
                    train_loader=_make_loader(
                        data,
                        splits["train"],
                        batch_size=batch_size,
                        shuffle=True,
                        los_mean=los_mean,
                        los_std=los_std,
                        source_id=main_source_id,
                        missingness_aware=missingness_aware,
                        delta_clip_hours=delta_clip_hours,
                        gru_d_imputation=gru_d_imputation,
                        num_workers=num_workers,
                        pin_memory=bool(pin_memory),
                    ),
                    val_loader=_make_loader(
                        data,
                        splits["val"],
                        batch_size=batch_size,
                        shuffle=False,
                        los_mean=los_mean,
                        los_std=los_std,
                        source_id=main_source_id,
                        missingness_aware=missingness_aware,
                        delta_clip_hours=delta_clip_hours,
                        gru_d_imputation=gru_d_imputation,
                        num_workers=num_workers,
                        pin_memory=bool(pin_memory),
                    ),
                    source_id=main_source_id,
                    is_main=True,
                )
            )
            balanced_stage_summaries.append(
                _source_summary(
                    name="s0",
                    source_s0_dir=Path(s0_dir),
                    source_data=data,
                    source_splits=splits,
                    source_los_mean=los_mean,
                    source_los_std=los_std,
                    source_id=main_source_id,
                    epochs_trained=0,
                    is_main=True,
                )
            )

        for aux_source_index, aux_source in enumerate(normalized_aux_sources):
            aux_name = str(aux_source.get("name") or f"aux{aux_source_index + 1}")
            source_s0_dir = aux_source.get("s0_dir")
            source_splits_path = aux_source.get("splits_path")
            if source_s0_dir is None:
                continue
            aux_data = load_trajectory_data(
                s0_dir=Path(source_s0_dir),
                s2_dir=None,
                splits_path=Path(source_splits_path) if source_splits_path is not None else None,
                seed=seed,
            )
            if aux_data.input_dim != data.input_dim:
                raise ValueError(f"aux input_dim={aux_data.input_dim} does not match main input_dim={data.input_dim}")
            aux_splits = {name: values.copy() for name, values in aux_data.splits.items()}
            if max_aux_train_patients is not None:
                aux_splits["train"] = aux_splits["train"][: int(max_aux_train_patients)]
            if max_aux_eval_patients is not None:
                aux_splits["val"] = aux_splits["val"][: int(max_aux_eval_patients)]
                aux_splits["test"] = aux_splits["test"][: int(max_aux_eval_patients)]
            aux_los_mean, aux_los_std = _fit_los_scaler(aux_data, aux_splits["train"])
            source_id = len(bundles)
            aux_train_loader = _make_loader(
                aux_data,
                aux_splits["train"],
                batch_size=batch_size,
                shuffle=True,
                los_mean=aux_los_mean,
                los_std=aux_los_std,
                source_id=source_id,
                missingness_aware=missingness_aware,
                delta_clip_hours=delta_clip_hours,
                gru_d_imputation=gru_d_imputation,
                num_workers=num_workers,
                pin_memory=bool(pin_memory),
            )
            aux_val_loader = _make_loader(
                aux_data,
                aux_splits["val"],
                batch_size=batch_size,
                shuffle=False,
                los_mean=aux_los_mean,
                los_std=aux_los_std,
                source_id=source_id,
                missingness_aware=missingness_aware,
                delta_clip_hours=delta_clip_hours,
                gru_d_imputation=gru_d_imputation,
                num_workers=num_workers,
                pin_memory=bool(pin_memory),
            )
            bundles.append(
                SourceTrainingBundle(
                    name=aux_name,
                    data=aux_data,
                    splits=aux_splits,
                    los_mean=aux_los_mean,
                    los_std=aux_los_std,
                    train_loader=aux_train_loader,
                    val_loader=aux_val_loader,
                    source_id=source_id,
                    is_main=False,
                )
            )
            summary = _source_summary(
                name=aux_name,
                source_s0_dir=Path(source_s0_dir),
                source_data=aux_data,
                source_splits=aux_splits,
                source_los_mean=aux_los_mean,
                source_los_std=aux_los_std,
                source_id=source_id,
                epochs_trained=0,
                is_main=False,
            )
            aux_stage_summaries.append(summary)
            balanced_stage_summaries.append(summary)

        stage_history, _, _ = _train_source_balanced_auxiliary_stage(
            model=train_model,
            bundles=bundles,
            output_dir=output_dir,
            stage_name="source_balanced_aux",
            epochs=aux_epochs,
            steps_per_epoch=balanced_steps_per_epoch,
            lr=lr,
            weight_decay=weight_decay,
            patience=aux_patience,
            lambda_mortality=lambda_mortality,
            lambda_sepsis=lambda_sepsis,
            lambda_los=lambda_los,
            lambda_next_mv=lambda_next_mv,
            lambda_next_rrt=lambda_next_rrt,
            domain_invariance=domain_mode,
            lambda_domain=lambda_domain,
            domain_grl_lambda=domain_grl_lambda,
            source_objective=objective_mode,
            group_dro_eta=group_dro_eta,
            lambda_phenotype=lambda_phenotype,
            lambda_phenotype_contrastive=lambda_phenotype_contrastive,
            phenotype_contrastive_temperature=phenotype_contrastive_temperature,
            device=device,
        )
        aux_history.extend(stage_history)
        for summary in balanced_stage_summaries:
            summary["epochs_trained"] = len(stage_history)

    elif aux_mode == "sequential":
        for aux_source_index, aux_source in enumerate(normalized_aux_sources):
            if aux_epochs <= 0:
                break
            aux_name = str(aux_source.get("name") or f"aux{aux_source_index + 1}")
            source_s0_dir = aux_source.get("s0_dir")
            source_splits_path = aux_source.get("splits_path")
            if source_s0_dir is None:
                continue
            aux_data = load_trajectory_data(
                s0_dir=Path(source_s0_dir),
                s2_dir=None,
                splits_path=Path(source_splits_path) if source_splits_path is not None else None,
                seed=seed,
            )
            if aux_data.input_dim != data.input_dim:
                raise ValueError(f"aux input_dim={aux_data.input_dim} does not match main input_dim={data.input_dim}")
            aux_splits = {name: values.copy() for name, values in aux_data.splits.items()}
            if max_aux_train_patients is not None:
                aux_splits["train"] = aux_splits["train"][: int(max_aux_train_patients)]
            if max_aux_eval_patients is not None:
                aux_splits["val"] = aux_splits["val"][: int(max_aux_eval_patients)]
                aux_splits["test"] = aux_splits["test"][: int(max_aux_eval_patients)]
            aux_los_mean, aux_los_std = _fit_los_scaler(aux_data, aux_splits["train"])
            aux_train_loader = _make_loader(
                aux_data,
                aux_splits["train"],
                batch_size=batch_size,
                shuffle=True,
                los_mean=aux_los_mean,
                los_std=aux_los_std,
                missingness_aware=missingness_aware,
                delta_clip_hours=delta_clip_hours,
                gru_d_imputation=gru_d_imputation,
                num_workers=num_workers,
                pin_memory=bool(pin_memory),
            )
            aux_val_loader = _make_loader(
                aux_data,
                aux_splits["val"],
                batch_size=batch_size,
                shuffle=False,
                los_mean=aux_los_mean,
                los_std=aux_los_std,
                missingness_aware=missingness_aware,
                delta_clip_hours=delta_clip_hours,
                gru_d_imputation=gru_d_imputation,
                num_workers=num_workers,
                pin_memory=bool(pin_memory),
            )
            stage_name = f"aux_{aux_source_index + 1}_{aux_name}"
            stage_history, _, _ = _train_auxiliary_stage(
                model=train_model,
                train_loader=aux_train_loader,
                val_loader=aux_val_loader,
                output_dir=output_dir,
                stage_name=stage_name,
                epochs=aux_epochs,
                lr=lr,
                weight_decay=weight_decay,
                patience=aux_patience,
                lambda_mortality=lambda_mortality,
                lambda_sepsis=lambda_sepsis,
                lambda_los=lambda_los,
                lambda_next_mv=lambda_next_mv,
                lambda_next_rrt=lambda_next_rrt,
                lambda_phenotype=lambda_phenotype,
                lambda_phenotype_contrastive=lambda_phenotype_contrastive,
                phenotype_contrastive_temperature=phenotype_contrastive_temperature,
                los_mean=aux_los_mean,
                los_std=aux_los_std,
                device=device,
            )
            aux_history.extend(stage_history)
            aux_stage_summaries.append(
                _source_summary(
                    name=aux_name,
                    source_s0_dir=Path(source_s0_dir),
                    source_data=aux_data,
                    source_splits=aux_splits,
                    source_los_mean=aux_los_mean,
                    source_los_std=aux_los_std,
                    source_id=None,
                    epochs_trained=len(stage_history),
                    is_main=False,
                )
            )

    history, best_state, _ = _train_auxiliary_stage(
        model=train_model,
        train_loader=train_loader,
        val_loader=val_loader,
        output_dir=output_dir,
        stage_name="s0_aux",
        epochs=epochs,
        lr=lr,
        weight_decay=weight_decay,
        patience=patience,
        lambda_mortality=lambda_mortality,
        lambda_sepsis=lambda_sepsis,
        lambda_los=lambda_los,
        lambda_next_mv=lambda_next_mv,
        lambda_next_rrt=lambda_next_rrt,
        lambda_phenotype=lambda_phenotype,
        lambda_phenotype_contrastive=lambda_phenotype_contrastive,
        phenotype_contrastive_temperature=phenotype_contrastive_temperature,
        los_mean=los_mean,
        los_std=los_std,
        device=device,
    )
    if best_state is not None:
        torch.save({"model_state_dict": best_state}, output_dir / "checkpoints" / "trajectory_encoder_best.pt")

    init_probs, transition_probs = fit_transition_matrix(
        data.phenotype_labels,
        splits["train"],
        n_classes=data.n_classes,
        alpha=transition_alpha,
    )

    train_embed_loader = _make_loader(
        data,
        splits["train"],
        batch_size=batch_size,
        shuffle=False,
        los_mean=los_mean,
        los_std=los_std,
        missingness_aware=missingness_aware,
        delta_clip_hours=delta_clip_hours,
        gru_d_imputation=gru_d_imputation,
        num_workers=num_workers,
        pin_memory=bool(pin_memory),
        include_patient_window=True,
    )
    train_emb, train_y, train_windows, _train_patients = _extract_embeddings(
        model,
        train_embed_loader,
        device=device,
        n_classes=data.n_classes,
    )
    readout = make_pipeline(
        StandardScaler(),
        LogisticRegression(max_iter=2000, class_weight="balanced", random_state=seed),
    )
    readout.fit(_augment_embeddings_with_window(train_emb, train_windows, data.n_windows), train_y)
    with open(output_dir / "phenotype_readout.pkl", "wb") as f:
        pickle.dump(readout, f)

    report_splits: dict[str, Any] = {}
    rule_probs_all = compute_rule_probabilities(data, temperature=rule_temperature)
    rule_pred_all = rule_probs_all.argmax(axis=-1)
    rule_smooth_all = viterbi_smooth(
        rule_probs_all,
        init_probs,
        transition_probs,
        transition_weight=transition_weight,
    )

    for split_name, patient_idx in splits.items():
        eval_loader = _make_loader(
            data,
            patient_idx,
            batch_size=batch_size,
            shuffle=False,
            los_mean=los_mean,
            los_std=los_std,
            include_patient_window=True,
            missingness_aware=missingness_aware,
            delta_clip_hours=delta_clip_hours,
            gru_d_imputation=gru_d_imputation,
            num_workers=num_workers,
            pin_memory=bool(pin_memory),
        )
        emb, y_flat, windows, patients = _extract_embeddings(model, eval_loader, device=device, n_classes=data.n_classes)
        encoder_probs = _readout_probs_by_patient(
            readout,
            emb,
            windows,
            patients,
            patient_idx,
            n_windows=data.n_windows,
            n_classes=data.n_classes,
        )
        encoder_pred = encoder_probs.argmax(axis=-1)
        encoder_smooth = viterbi_smooth(
            encoder_probs,
            init_probs,
            transition_probs,
            transition_weight=transition_weight,
        )
        y_true = data.phenotype_labels[patient_idx]
        report_splits[split_name] = {
            "raw_rule": _metrics_for_predictions(y_true, rule_pred_all[patient_idx]),
            "rule_plus_transition_smoothing": _metrics_for_predictions(y_true, rule_smooth_all[patient_idx]),
            "encoder_readout": _metrics_for_predictions(y_true, encoder_pred),
            "encoder_plus_transition_smoothing": _metrics_for_predictions(y_true, encoder_smooth),
            "auxiliary": _evaluate_auxiliary(
                model,
                eval_loader,
                device=device,
                los_mean=los_mean,
                los_std=los_std,
            ),
            "n_patients": int(len(patient_idx)),
            "n_windows": int(data.n_windows),
            "n_samples": int(len(y_flat)),
        }

    torch.save(
        {
            "model_state_dict": _state_dict_for_save(model),
            "config": {
                "input_dim": input_dim,
                "hidden_dim": hidden_dim,
                "embedding_dim": embedding_dim,
                "recurrent": recurrent,
                "num_layers": num_layers,
                "dropout": dropout,
                "n_sources": n_source_head,
                "n_phenotype_classes": data.n_classes if (lambda_phenotype > 0 or lambda_phenotype_contrastive > 0) else 0,
                "missingness_aware": bool(missingness_aware),
                "delta_clip_hours": float(delta_clip_hours),
                "gru_d_imputation": bool(gru_d_imputation),
                "gru_d_n_continuous": int(n_continuous_features),
                "gru_d_side_dim": int(side_dim),
                "data_parallel_gpus": int(data_parallel_gpus),
            },
            "los_mean": los_mean,
            "los_std": los_std,
            "transition_init_probs": init_probs,
            "transition_probs": transition_probs,
        },
        output_dir / "trajectory_encoder.pt",
    )
    np.save(output_dir / "transition_init_probs.npy", init_probs)
    np.save(output_dir / "transition_probs.npy", transition_probs)

    report = {
        "experiment": "s6_trajectory_encoder",
        "generated_at": pd.Timestamp.now().isoformat(timespec="seconds"),
        "data": {
            "s0_dir": str(Path(s0_dir)),
            "s2_dir": str(Path(s2_dir)),
            "aux_s0_dir": str(Path(aux_s0_dir)) if aux_s0_dir is not None else None,
            "aux_sources": aux_stage_summaries,
            "balanced_sources": balanced_stage_summaries,
            "n_patients": data.n_patients,
            "n_windows": data.n_windows,
            "n_classes": data.n_classes,
            "window_starts": data.window_starts,
            "window_len": data.window_len,
            "stride": data.stride,
            "base_input_dim": data.input_dim,
            "input_dim": input_dim,
            "missingness_aware_delta_dim": int(input_dim - data.input_dim),
            "split_sizes": {name: int(len(values)) for name, values in splits.items()},
            "next_mv_coverage": float(np.mean(data.next_mv_masks[splits["train"]] > 0)),
            "next_rrt_coverage": float(np.mean(data.next_rrt_masks[splits["train"]] > 0)),
            "sepsis_label_coverage": float(np.mean(data.sepsis_masks[splits["train"]] > 0)),
            "auxiliary": aux_stage_summaries[-1] if aux_stage_summaries else None,
        },
        "leakage_guard": {
            "patient_level_split": True,
            "los_scaler_fit_on": "train_only",
            "auxiliary_pretraining_uses_phenotype_labels": bool(
                lambda_phenotype > 0 or lambda_phenotype_contrastive > 0
            ),
            "phenotype_supervision_source": (
                "main_source_only" if (lambda_phenotype > 0 or lambda_phenotype_contrastive > 0) else None
            ),
            "auxiliary_pretraining_sources": [str(item["s0_dir"]) for item in aux_stage_summaries],
            "source_balanced_training_uses_phenotype_labels": bool(
                (lambda_phenotype > 0 or lambda_phenotype_contrastive > 0)
                and balanced_include_main_source
            ),
            "external_sources_use_phenotype_labels": False,
            "source_balanced_sources": [str(item["s0_dir"]) for item in balanced_stage_summaries],
            "transition_matrix_fit_on": "train_only phenotype trajectories",
            "phenotype_readout_fit_on": "train_only encoder embeddings and train phenotype labels",
            "encoder_training_uses_phenotype_labels": bool(
                lambda_phenotype > 0 or lambda_phenotype_contrastive > 0
            ),
            "future_input_masking": "hours after current window end are zeroed before encoder input",
            "next_treatment_targets": "non-overlapping future stride after current window",
        },
        "model": {
            "recurrent": recurrent,
            "hidden_dim": hidden_dim,
            "embedding_dim": embedding_dim,
            "num_layers": num_layers,
            "dropout": dropout,
            "n_sources": n_source_head,
            "n_phenotype_classes": data.n_classes if (lambda_phenotype > 0 or lambda_phenotype_contrastive > 0) else 0,
            "missingness_aware": bool(missingness_aware),
            "delta_clip_hours": float(delta_clip_hours),
            "gru_d_imputation": bool(gru_d_imputation),
            "gru_d_n_continuous": int(n_continuous_features),
            "gru_d_side_dim": int(side_dim),
            "n_parameters": int(sum(p.numel() for p in model.parameters())),
            "data_parallel_gpus": int(data_parallel_gpus),
        },
        "training": {
            "epochs_requested": epochs,
            "epochs_trained": len(history),
            "aux_epochs_requested": aux_epochs,
            "aux_epochs_trained": len(aux_history),
            "aux_training_mode": aux_mode,
            "balanced_include_main_source": bool(balanced_include_main_source),
            "balanced_steps_per_epoch": balanced_steps_per_epoch,
            "domain_invariance": domain_mode,
            "lambda_domain": lambda_domain,
            "domain_grl_lambda": domain_grl_lambda,
            "source_objective": objective_mode,
            "group_dro_eta": group_dro_eta,
            "missingness_aware": bool(missingness_aware),
            "delta_clip_hours": float(delta_clip_hours),
            "batch_size": batch_size,
            "lr": lr,
            "weight_decay": weight_decay,
            "data_parallel_gpus": int(data_parallel_gpus),
            "num_workers": int(num_workers),
            "pin_memory": bool(pin_memory),
            "lambda_mortality": lambda_mortality,
            "lambda_sepsis": lambda_sepsis,
            "lambda_los": lambda_los,
            "lambda_next_mv": lambda_next_mv,
            "lambda_next_rrt": lambda_next_rrt,
            "lambda_phenotype": lambda_phenotype,
            "lambda_phenotype_contrastive": lambda_phenotype_contrastive,
            "phenotype_contrastive_temperature": phenotype_contrastive_temperature,
            "patience": patience,
            "seed": seed,
            "device": device,
            "los_mean_log1p_train": los_mean,
            "los_std_log1p_train": los_std,
            "aux_los_mean_log1p_train": aux_los_mean if aux_stage_summaries else None,
            "aux_los_std_log1p_train": aux_los_std if aux_stage_summaries else None,
        },
        "transition": {
            "alpha": transition_alpha,
            "transition_weight": transition_weight,
            "init_probs": init_probs.round(6).tolist(),
            "transition_probs": transition_probs.round(6).tolist(),
        },
        "auxiliary_history": aux_history,
        "history": history,
        "combined_history": aux_history + history,
        "splits": report_splits,
        "existing_webapp_rule_export": _export_existing_consistency(Path(s0_dir)),
        "outputs": {
            "report": str(output_dir / "trajectory_encoder_report.json"),
            "model": str(output_dir / "trajectory_encoder.pt"),
            "readout": str(output_dir / "phenotype_readout.pkl"),
        },
    }

    with open(output_dir / "trajectory_encoder_report.json", "w", encoding="utf-8") as f:
        json.dump(report, f, ensure_ascii=False, indent=2)
    return report
