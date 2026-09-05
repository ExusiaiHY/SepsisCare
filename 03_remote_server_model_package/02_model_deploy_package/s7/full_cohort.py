"""S7 all-source training orchestration.

S7 intentionally changes the role of the external cohorts: PhysioNet 2019,
MIMIC-IV, and eICU-CRD are training sources rather than external validation
sets. Any validation/test metrics emitted by this stage are monitoring-only
because their split files overlap the training set by design.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pandas as pd
import yaml

from s6.trajectory_encoder import train_trajectory_encoder


@dataclass(frozen=True)
class S7Source:
    name: str
    s0_dir: Path
    s2_dir: Path | None = None
    role: str = "train"


def read_s7_config(config_path: Path) -> dict[str, Any]:
    """Read a YAML S7 config."""
    with open(config_path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)


def resolve_project_path(project_root: Path, value: str | Path | None) -> Path | None:
    """Resolve a path relative to the project root."""
    if value in {None, ""}:
        return None
    path = Path(value)
    return path if path.is_absolute() else Path(project_root) / path


def load_sources_from_config(config: dict[str, Any], project_root: Path) -> list[S7Source]:
    """Materialize source descriptors from ``sources`` config entries."""
    sources: list[S7Source] = []
    for raw in config.get("sources", []):
        name = str(raw["name"])
        s0_dir = resolve_project_path(project_root, raw["s0_dir"])
        if s0_dir is None:
            raise ValueError(f"S7 source {name!r} is missing s0_dir")
        s2_dir = resolve_project_path(project_root, raw.get("s2_dir"))
        sources.append(
            S7Source(
                name=name,
                s0_dir=s0_dir,
                s2_dir=s2_dir,
                role=str(raw.get("role", "train")),
            )
        )
    if not sources:
        raise ValueError("S7 requires at least one source")
    return sources


def build_full_overlap_split(
    s0_dir: Path,
    split_path: Path,
    *,
    max_patients: int | None = None,
) -> dict[str, list[int]]:
    """Write a train/val/test split where all split names contain all patients.

    ``train`` is the full cohort. ``val`` and ``test`` intentionally overlap it
    so existing training code can still run early stopping and monitoring. S7
    reports these metrics as in-sample monitoring, not held-out validation.
    """
    static_path = Path(s0_dir) / "static.csv"
    static = pd.read_csv(static_path, usecols=[0])
    n_patients = int(len(static))
    if max_patients is not None:
        n_patients = min(n_patients, int(max_patients))
    indices = list(range(n_patients))
    payload = {
        "train": indices,
        "val": indices,
        "test": indices,
    }
    split_path = Path(split_path)
    split_path.parent.mkdir(parents=True, exist_ok=True)
    split_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    return payload


def prepare_s7_splits(
    *,
    sources: list[S7Source],
    output_dir: Path,
    max_patients_by_source: dict[str, int] | None = None,
) -> dict[str, dict[str, Any]]:
    """Create S7 full-overlap split files for all sources."""
    split_root = Path(output_dir) / "splits"
    split_root.mkdir(parents=True, exist_ok=True)
    max_patients_by_source = max_patients_by_source or {}
    prepared: dict[str, dict[str, Any]] = {}
    for source in sources:
        max_patients = max_patients_by_source.get(source.name)
        split_path = split_root / f"{source.name}_all_train_splits.json"
        splits = build_full_overlap_split(source.s0_dir, split_path, max_patients=max_patients)
        prepared[source.name] = {
            "name": source.name,
            "role": source.role,
            "s0_dir": str(source.s0_dir),
            "s2_dir": str(source.s2_dir) if source.s2_dir is not None else None,
            "splits_path": str(split_path),
            "split_sizes": {name: len(values) for name, values in splits.items()},
            "split_policy": "full_overlap_all_patients",
            "heldout": False,
        }
    return prepared


def run_s7_all_source_training(
    *,
    config: dict[str, Any],
    project_root: Path,
) -> dict[str, Any]:
    """Run S7 all-source trajectory encoder training."""
    project_root = Path(project_root)
    sources = load_sources_from_config(config, project_root)
    main_source_name = str(config.get("main_source", sources[0].name))
    by_name = {source.name: source for source in sources}
    if main_source_name not in by_name:
        raise ValueError(f"main_source={main_source_name!r} is not listed in sources")

    paths_cfg = config.get("paths", {})
    output_dir = resolve_project_path(project_root, paths_cfg.get("output_dir", "data/s7_all_sources"))
    if output_dir is None:
        raise ValueError("S7 output_dir could not be resolved")
    output_dir.mkdir(parents=True, exist_ok=True)

    smoke_cfg = config.get("smoke_limits", {}) or {}
    max_patients_by_source = {
        str(name): int(value)
        for name, value in smoke_cfg.get("max_patients_by_source", {}).items()
        if value is not None
    }
    prepared = prepare_s7_splits(
        sources=sources,
        output_dir=output_dir,
        max_patients_by_source=max_patients_by_source,
    )

    main = by_name[main_source_name]
    if main.s2_dir is None:
        raise ValueError(f"S7 main source {main_source_name!r} requires s2_dir")
    aux_sources = [
        {
            "name": source.name,
            "s0_dir": source.s0_dir,
            "splits_path": Path(prepared[source.name]["splits_path"]),
        }
        for source in sources
        if source.name != main_source_name
    ]

    training_cfg = config.get("training", {})
    model_cfg = config.get("model", {})
    runtime_cfg = config.get("runtime", {})

    report = train_trajectory_encoder(
        s0_dir=main.s0_dir,
        s2_dir=main.s2_dir,
        output_dir=output_dir,
        splits_path=Path(prepared[main_source_name]["splits_path"]),
        aux_sources=aux_sources,
        aux_epochs=int(training_cfg.get("aux_epochs", 1)),
        aux_patience=int(training_cfg.get("aux_patience", 2)),
        aux_training_mode=str(training_cfg.get("aux_training_mode", "source-balanced")),
        balanced_include_main_source=bool(training_cfg.get("balanced_include_main_source", True)),
        balanced_steps_per_epoch=training_cfg.get("balanced_steps_per_epoch"),
        domain_invariance=str(training_cfg.get("domain_invariance", "none")),
        lambda_domain=float(training_cfg.get("lambda_domain", 0.1)),
        domain_grl_lambda=float(training_cfg.get("domain_grl_lambda", 1.0)),
        source_objective=str(training_cfg.get("source_objective", "mean")),
        group_dro_eta=float(training_cfg.get("group_dro_eta", 0.05)),
        missingness_aware=bool(model_cfg.get("missingness_aware", False)),
        delta_clip_hours=float(model_cfg.get("delta_clip_hours", 48.0)),
        gru_d_imputation=bool(model_cfg.get("gru_d_imputation", False)),
        recurrent=str(model_cfg.get("recurrent", "gru")),
        hidden_dim=int(model_cfg.get("hidden_dim", 64)),
        embedding_dim=int(model_cfg.get("embedding_dim", 64)),
        num_layers=int(model_cfg.get("num_layers", 1)),
        dropout=float(model_cfg.get("dropout", 0.1)),
        batch_size=int(training_cfg.get("batch_size", 512)),
        epochs=int(training_cfg.get("epochs", 0)),
        lr=float(training_cfg.get("lr", 1.0e-3)),
        weight_decay=float(training_cfg.get("weight_decay", 1.0e-4)),
        patience=int(training_cfg.get("patience", 2)),
        lambda_mortality=float(training_cfg.get("lambda_mortality", 1.0)),
        lambda_sepsis=float(training_cfg.get("lambda_sepsis", 1.0)),
        lambda_los=float(training_cfg.get("lambda_los", 0.5)),
        lambda_next_mv=float(training_cfg.get("lambda_next_mv", 0.5)),
        lambda_next_rrt=float(training_cfg.get("lambda_next_rrt", 0.5)),
        lambda_phenotype=float(training_cfg.get("lambda_phenotype", 0.0)),
        lambda_phenotype_contrastive=float(training_cfg.get("lambda_phenotype_contrastive", 0.0)),
        phenotype_contrastive_temperature=float(training_cfg.get("phenotype_contrastive_temperature", 0.2)),
        transition_alpha=float(training_cfg.get("transition_alpha", 1.0)),
        transition_weight=float(training_cfg.get("transition_weight", 1.0)),
        rule_temperature=float(training_cfg.get("rule_temperature", 12.0)),
        seed=int(runtime_cfg.get("seed", 42)),
        device=str(runtime_cfg.get("device", "cpu")),
        num_workers=int(runtime_cfg.get("num_workers", 0)),
        pin_memory=bool(runtime_cfg.get("pin_memory", str(runtime_cfg.get("device", "cpu")).startswith("cuda"))),
        max_train_patients=None,
        max_eval_patients=None,
        max_aux_train_patients=None,
        max_aux_eval_patients=None,
    )

    s7_summary = {
        "stage": "s7_all_source_training",
        "generated_at": pd.Timestamp.now().isoformat(timespec="seconds"),
        "intent": (
            "Use every configured cohort as training data. Monitoring splits "
            "intentionally overlap train and must not be interpreted as held-out validation."
        ),
        "main_source": main_source_name,
        "sources": prepared,
        "total_train_patients": int(sum(item["split_sizes"]["train"] for item in prepared.values())),
        "split_policy": {
            "train": "all patients per source",
            "val": "same patients as train for early-stopping/monitoring compatibility",
            "test": "same patients as train for in-sample monitoring compatibility",
            "heldout_external_validation": False,
        },
        "s6_report_path": report["outputs"]["report"],
        "s7_summary_path": str(output_dir / "s7_all_source_training_summary.json"),
    }
    report["s7"] = s7_summary
    report["leakage_guard"]["s7_all_sources_used_for_training"] = True
    report["leakage_guard"]["s7_monitoring_splits_overlap_train"] = True
    report["leakage_guard"]["s7_heldout_validation"] = False
    report["data"]["s7_sources"] = prepared
    report["data"]["s7_total_train_patients"] = s7_summary["total_train_patients"]

    report_path = output_dir / "trajectory_encoder_report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    (output_dir / "s7_all_source_training_summary.json").write_text(
        json.dumps(s7_summary, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return report
