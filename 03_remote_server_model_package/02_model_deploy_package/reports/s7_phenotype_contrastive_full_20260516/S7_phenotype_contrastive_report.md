# S7 Phenotype CE/SupCon Report

## Research Basis
- Supervised Contrastive Learning: uses labels to pull same-class embeddings together and separate different-class embeddings.
- Recent medical time-series domain-adaptation work is also moving toward contrastive, feature-invariant representations across domains.
- Recent EHR representation work similarly uses contrastive objectives to learn discriminative patient representations from sparse, irregular clinical time series.

## Scope
- Goal: explain low S7 phenotype F1 and try a newer representation-learning update.
- Update: add a direct phenotype cross-entropy head plus supervised contrastive regularization on the main S0 phenotype-labeled source.
- External cohorts still contribute auxiliary outcome/treatment losses only; they do not use phenotype labels.
- The capped trial used S0 plus 10,000 patients per external source; the full run used all 347,634 configured patients.
- Caveat: S7 val/test splits overlap train by design, so S7 metrics are in-sample monitoring, not held-out validation.

## Results
- Primary run: `S7 + phenotype CE/SupCon full`.
- Macro F1: `0.956`; encoder-only F1: `0.971`.
- Mortality AUROC: `0.848`; next-MV AUROC: `0.968`; LOS MAE: `2.955` h.
- Training used `7` GPUs and `347634` patients.

## Delta vs S7 Baseline
- Macro F1 delta: `+0.187`.
- Encoder-only macro F1 delta: `+0.241`.
- Transition smoothing delta changed from `+0.040` in baseline S7 to `-0.015` in the phenotype-supervised trial.
- Mortality AUROC delta: `-0.062`.
- LOS MAE delta: `+1.676` h.

## Ranking
- Best macro F1 in this comparison: `S7 + phenotype CE/SupCon capped` at `0.957`.

## Diagnosis
- The previous S7 run optimized auxiliary mortality/sepsis/LOS/next-treatment tasks, then learned phenotype mapping only after encoder training through a logistic readout. That explains why auxiliary AUROC improved while phenotype F1 lagged.
- The update directly shapes the embedding with phenotype labels and pulls same-phenotype windows closer while pushing different phenotypes apart.
- In this trial, transition smoothing is no longer helpful: encoder-only macro F1 is higher than encoder+transition macro F1, so the next variant should lower `transition_weight` or tune it on a held-out split.
- Auxiliary mortality and LOS degraded versus full S7, so the new objective improves phenotype clustering but shifts capacity away from outcome calibration.

## Visual Outputs
- `macro_f1_strategy_comparison.png`
- `s7_method_ablation_macro_f1.png`
- `phenotype_training_monitor.png`
- `auxiliary_auroc_comparison.png`
- `remaining_los_mae_comparison.png`
- `macro_f1_vs_mortality_auroc.png`

## Data Files
- `phenotype_strategy_summary.csv`
- `phenotype_method_metrics.csv`
- `phenotype_training_history.csv`