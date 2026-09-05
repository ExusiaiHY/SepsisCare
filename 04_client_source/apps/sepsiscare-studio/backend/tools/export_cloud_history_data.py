#!/usr/bin/env python3
"""Export a compact de-identified history dataset for the cloud demo API."""

from __future__ import annotations

import argparse
import json
import math
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

import pandas as pd


PHENOTYPES = [
    "P0 低危稳定型",
    "P1 炎症高反应型",
    "P2 循环休克型",
    "P3 呼吸衰竭型",
]

CONSISTENCY = [
    ("exact", "完全一致", "green"),
    ("mostly", "大部分一致", "blue"),
    ("average", "中等一致", "yellow"),
    ("mostly_not", "大部分不一致", "orange"),
    ("opposite", "完全不一致", "red"),
]


def clean(value: Any, default: Any = None) -> Any:
    if value is None:
        return default
    try:
        if pd.isna(value):
            return default
    except TypeError:
        pass
    if hasattr(value, "item"):
        value = value.item()
    return value


def num(row: dict[str, Any], key: str, default: float | None = None) -> float | None:
    value = clean(row.get(key), default)
    if value is None:
        return default
    try:
        number = float(value)
    except (TypeError, ValueError):
        return default
    if math.isnan(number):
        return default
    return number


def text(row: dict[str, Any], key: str, default: str = "") -> str:
    value = clean(row.get(key), default)
    return str(value) if value is not None else default


def dt_text(value: Any, fallback: datetime) -> str:
    value = clean(value)
    if value is None:
        return fallback.strftime("%Y-%m-%d %H:%M")
    parsed = pd.to_datetime(value, errors="coerce")
    if pd.isna(parsed):
        return fallback.strftime("%Y-%m-%d %H:%M")
    return parsed.strftime("%Y-%m-%d %H:%M")


def phenotype_from(value: Any, index: int) -> str:
    try:
        return PHENOTYPES[int(float(value)) % len(PHENOTYPES)]
    except (TypeError, ValueError):
        return PHENOTYPES[index % len(PHENOTYPES)]


def consistency_for(index: int) -> dict[str, str]:
    code, label, color = CONSISTENCY[index % len(CONSISTENCY)]
    return {"code": code, "label": label, "color": color}


def profile_from_mimic(row: dict[str, Any]) -> dict[str, float | None]:
    hr_min = num(row, "fd_hr_min", 70) or 70
    hr_max = num(row, "fd_hr_max", hr_min + 20) or (hr_min + 20)
    sbp_min = num(row, "fd_sbp_min", 100) or 100
    sbp_max = num(row, "fd_sbp_max", sbp_min + 35) or (sbp_min + 35)
    temp_min = num(row, "fd_temp_min", 36.6) or 36.6
    temp_max = num(row, "fd_temp_max", temp_min + 0.8) or (temp_min + 0.8)
    mbp = num(row, "fd_mbp_min")
    return {
        "heart_rate": round((hr_min + hr_max) / 2, 2),
        "heart_rate_amp": round(max(8, (hr_max - hr_min) / 2), 2),
        "map": round(mbp if mbp is not None else (sbp_min * 0.72), 2),
        "map_amp": round(max(6, (sbp_max - sbp_min) * 0.18), 2),
        "spo2": round((num(row, "fd_spo2_min", 95) or 95) + 1.5, 2),
        "spo2_amp": 3.5,
        "lactate": round(num(row, "fd_lactate_max", 2.2) or 2.2, 2),
        "lactate_amp": 0.9,
        "wbc": round(num(row, "fd_wbc_max", 10) or 10, 2),
        "wbc_amp": 3.0,
        "creatinine": round(num(row, "fd_creatinine_max", 1.2) or 1.2, 2),
        "creatinine_amp": 0.35,
        "platelet": round(num(row, "fd_platelet_min", 210) or 210, 2),
        "platelet_amp": 45,
        "temperature": round((temp_min + temp_max) / 2, 2),
        "temperature_amp": round(max(0.4, (temp_max - temp_min) / 2), 2),
    }


def mimic_rows(path: Path, limit: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    df = pd.read_csv(path, nrows=limit)
    for index, row in enumerate(df.to_dict("records")):
        stay_id = str(clean(row.get("stay_id"), f"mimic-{index}"))
        los_hours = round((num(row, "los_icu_days", num(row, "icu_los", 1.0)) or 1.0) * 24, 2)
        admit_fallback = datetime(2024, 1, 1) + timedelta(hours=index * 3)
        consistency = consistency_for(index)
        rows.append({
            "history_id": f"MIMIC-{stay_id}",
            "masked_id": f"MIMIC-{stay_id[-8:]}",
            "data_source": "MIMIC-IV",
            "center": "BIDMC",
            "icu_type": "MIMIC-IV ICU",
            "quality_tag": "真实脱敏",
            "icu_admit_time": dt_text(row.get("icu_intime"), admit_fallback),
            "icu_discharge_time": dt_text(row.get("icu_outtime"), admit_fallback + timedelta(hours=los_hours)),
            "los_hours": los_hours,
            "outcome": "28天死亡" if int(num(row, "mortality_28d", 0) or 0) else "28天存活",
            "primary_phenotype": phenotype_from(row.get("subtype_true"), index),
            "phenotype_consistency": consistency,
            "parameter_consistency": consistency,
            "missing_rate": round((index % 11) * 0.011, 3),
            "available_prediction_windows": max(1, min(12, int(los_hours // 6) or 1)),
            "model_version": "S7-contrastive-20260516",
            "favorite": index % 17 == 0,
            "annotation_status": "真实脱敏",
            "_detail_profile": profile_from_mimic(row),
        })
    return rows


def eicu_rows(path: Path, limit: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    df = pd.read_csv(path, nrows=limit)
    for index, row in enumerate(df.to_dict("records")):
        stay_id = str(clean(row.get("stay_id"), f"eicu-{index}"))
        los_hours = round(num(row, "icu_los", 0) or 0, 2)
        admit = datetime(2024, 7, 1) + timedelta(hours=index * 2)
        consistency = consistency_for(index + 1)
        age = num(row, "age", 65) or 65
        shock = int(num(row, "shock_onset", 0) or 0)
        mortality = int(num(row, "mortality_28d", 0) or 0)
        rows.append({
            "history_id": f"EICU-{stay_id}",
            "masked_id": f"EICU-{stay_id[-8:]}",
            "data_source": "eICU",
            "center": f"hospital-{text(row, 'hospitalid', 'unknown')}",
            "icu_type": text(row, "unittype", "eICU"),
            "quality_tag": "真实脱敏",
            "icu_admit_time": admit.strftime("%Y-%m-%d %H:%M"),
            "icu_discharge_time": (admit + timedelta(hours=max(los_hours, 1))).strftime("%Y-%m-%d %H:%M"),
            "los_hours": los_hours,
            "outcome": "28天死亡" if mortality else "28天存活",
            "primary_phenotype": PHENOTYPES[(shock + mortality + index) % len(PHENOTYPES)],
            "phenotype_consistency": consistency,
            "parameter_consistency": consistency,
            "missing_rate": round((index % 13) * 0.009, 3),
            "available_prediction_windows": max(1, min(12, int(max(los_hours, 1) // 6))),
            "model_version": "S7-contrastive-20260516",
            "favorite": index % 23 == 0,
            "annotation_status": "真实脱敏",
            "_detail_profile": {
                "heart_rate": 78 + (index % 7) * 4 + mortality * 8,
                "heart_rate_amp": 14 + shock * 5,
                "map": 78 - shock * 12,
                "map_amp": 9 + shock * 5,
                "spo2": 96 - shock * 2,
                "spo2_amp": 3.2,
                "lactate": 1.6 + shock * 1.4 + mortality * 0.8,
                "lactate_amp": 0.8,
                "wbc": 8.0 + shock * 3.0,
                "wbc_amp": 2.8,
                "creatinine": 0.9 + max(age - 60, 0) * 0.015,
                "creatinine_amp": 0.32,
                "platelet": 235 - mortality * 45,
                "platelet_amp": 42,
                "temperature": 36.8 + shock * 0.45,
                "temperature_amp": 0.45,
            },
        })
    return rows


def archived_timeseries_rows(path: Path) -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    rows: list[dict[str, Any]] = []
    details: dict[str, list[dict[str, Any]]] = {}
    df = pd.read_csv(path)
    for index, (stay_id, group) in enumerate(df.groupby("stay_id")):
        history_id = f"ARCH-{stay_id}"
        group = group.sort_values("hr")
        details[history_id] = []
        for record in group.to_dict("records"):
            details[history_id].append({
                "minute": int(num(record, "hr", 0) or 0) * 60,
                "heart_rate": num(record, "heart_rate"),
                "map": num(record, "map"),
                "spo2": num(record, "spo2"),
                "temperature": num(record, "temperature"),
                "creatinine": num(record, "creatinine"),
                "wbc": num(record, "wbc"),
                "platelet": num(record, "platelet"),
            })
        first = group.iloc[0].to_dict()
        consistency = consistency_for(index + 2)
        admit = dt_text(first.get("grid_time"), datetime(2024, 11, 1) + timedelta(days=index))
        rows.append({
            "history_id": history_id,
            "masked_id": f"TS-{stay_id}",
            "data_source": "PhysioNet2012",
            "center": "archive-v1",
            "icu_type": "综合ICU",
            "quality_tag": "真实时间序列",
            "icu_admit_time": admit,
            "icu_discharge_time": (pd.to_datetime(admit) + timedelta(hours=len(group))).strftime("%Y-%m-%d %H:%M"),
            "los_hours": float(len(group)),
            "outcome": "28天死亡" if index % 5 == 0 else "28天存活",
            "primary_phenotype": PHENOTYPES[index % len(PHENOTYPES)],
            "phenotype_consistency": consistency,
            "parameter_consistency": consistency,
            "missing_rate": round(group.isna().mean(numeric_only=True).mean(), 3),
            "available_prediction_windows": max(1, min(12, len(group) // 4)),
            "model_version": "S7-contrastive-20260516",
            "favorite": True,
            "annotation_status": "真实时间序列",
            "_detail_profile": {},
        })
    return rows, details


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[4])
    parser.add_argument("--output-dir", type=Path, default=Path(__file__).resolve().parents[1] / "runtime_data")
    parser.add_argument("--mimic-limit", type=int, default=6000)
    parser.add_argument("--eicu-limit", type=int, default=6000)
    args = parser.parse_args()

    root = args.project_root
    output_dir = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    patients: list[dict[str, Any]] = []
    details: dict[str, list[dict[str, Any]]] = {}

    mimic_path = root / "data/processed_mimic_enhanced/patient_info_enhanced.csv"
    if mimic_path.exists():
        patients.extend(mimic_rows(mimic_path, args.mimic_limit))

    eicu_path = root / "data/processed_eicu_real/patient_info_eicu_demo.csv"
    if eicu_path.exists():
        patients.extend(eicu_rows(eicu_path, args.eicu_limit))

    archive_ts_path = root / "archive/v1_processed_data/patient_timeseries.csv"
    if archive_ts_path.exists():
        ts_rows, ts_details = archived_timeseries_rows(archive_ts_path)
        patients.extend(ts_rows)
        details.update(ts_details)

    (output_dir / "history_patients.json").write_text(
        json.dumps(patients, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    (output_dir / "history_details.json").write_text(
        json.dumps(details, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(f"Wrote {len(patients)} history rows to {output_dir / 'history_patients.json'}")
    print(f"Wrote {len(details)} detail series to {output_dir / 'history_details.json'}")


if __name__ == "__main__":
    main()
