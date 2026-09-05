#!/usr/bin/env python3
"""Run S7 all-source training.

S7 uses every configured cohort for training. Any val/test metrics emitted by
this run are in-sample monitoring because S7 split files intentionally overlap
train/val/test.
"""
from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PROJECT_ROOT))

from s7.full_cohort import read_s7_config, run_s7_all_source_training


def get_device(pref: str) -> str:
    if pref != "auto":
        return pref
    try:
        import torch

        if torch.cuda.is_available():
            return "cuda"
        if torch.backends.mps.is_available():
            return "mps"
    except Exception:
        pass
    return "cpu"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="S7 all-source training")
    parser.add_argument("--config", default="config/s7_all_sources.yaml")
    parser.add_argument("--device", default=None, help="Override config runtime.device")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    logging.basicConfig(
        level=logging.INFO,
        format="[%(asctime)s] %(levelname)-8s %(name)s: %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        stream=sys.stdout,
    )
    logger = logging.getLogger("s7")
    config_path = Path(args.config)
    if not config_path.is_absolute():
        config_path = PROJECT_ROOT / config_path
    cfg = read_s7_config(config_path)
    runtime = cfg.setdefault("runtime", {})
    runtime["device"] = get_device(args.device or str(runtime.get("device", "auto")))

    report = run_s7_all_source_training(config=cfg, project_root=PROJECT_ROOT)
    logger.info("=" * 72)
    logger.info("S7 all-source training complete")
    logger.info("Total training patients: %s", report["data"]["s7_total_train_patients"])
    logger.info("Report: %s", report["outputs"]["report"])
    logger.info("Summary: %s", report["s7"]["s7_summary_path"])
    logger.info("=" * 72)


if __name__ == "__main__":
    main()

