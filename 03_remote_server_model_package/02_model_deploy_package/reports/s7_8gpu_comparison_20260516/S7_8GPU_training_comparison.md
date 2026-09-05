# S7 8GPU Training Comparison

## Scope
- Current run: `s7_all_sources_8gpu_20260516_1945`.
- Comparator set: full-size trajectory encoder reports under `project/data`, excluding smoke runs.
- Important caveat: S7 uses all configured cohorts for training and its train/val/test splits intentionally overlap. Its reported metrics are in-sample monitoring, not held-out external validation. Historical S6 test metrics are S0 held-out split metrics.

## Headline Metrics
- S7 all-source 8GPU trained on `347,634` patients and used `8` GPUs.
- S7 encoder+transition macro F1: `0.769`; window match: `0.777`; full-patient match: `0.587`.
- S7 auxiliary mortality AUROC: `0.911`; next-MV AUROC: `0.975`; remaining LOS MAE: `1.279` hours.
- Among selected historical reports, S7 ranks `8/9` by macro F1; best macro F1 is `0.821` from `S6 GRU baseline`.

## Comparison Against Key Prior Strategies
| Strategy | Split type | Macro F1 | Window match | Full patient | Mortality AUROC | LOS MAE h | Next MV AUROC |
|---|---:|---:|---:|---:|---:|---:|---:|
| S6 GRU baseline | held-out S0 test | 0.821 | 0.829 | 0.625 | 0.830 | 1.609 | 0.968 |
| Missingness-aware GroupDRO + S0 FT | held-out S0 test | 0.806 | 0.812 | 0.610 | 0.832 | 1.909 | 0.968 |
| Source-balanced + S0 FT | held-out S0 test | 0.789 | 0.794 | 0.591 | 0.831 | 2.137 | 0.967 |
| Source-balanced | held-out S0 test | 0.786 | 0.792 | 0.591 | 0.823 | 5.337 | 0.964 |
| LOSO: exclude MIMIC | held-out S0 test | 0.779 | 0.785 | 0.587 | 0.822 | 5.055 | 0.966 |
| LOSO: exclude eICU | held-out S0 test | 0.774 | 0.784 | 0.587 | 0.829 | 2.244 | 0.966 |
| S6 + PhysioNet2019 aux | held-out S0 test | 0.773 | 0.786 | 0.589 | 0.825 | 1.111 | 0.970 |
| S7 all-source 8GPU | in-sample monitoring | 0.769 | 0.777 | 0.587 | 0.911 | 1.279 | 0.975 |
| GRU-D GroupDRO | held-out S0 test | 0.677 | 0.683 | 0.506 | 0.762 | 3.023 | 0.962 |

## Interpretation
- Compared with `S6 GRU baseline`, S7 improves auxiliary mortality AUROC from `0.830` to `0.911` and next-MV AUROC from `0.968` to `0.975`. LOS MAE improves from `1.609` h to `1.279` h.
- For phenotype consistency, S7 macro F1 `0.769` is below the strongest S6 held-out runs (`S6 GRU baseline` `0.821` and `Missingness-aware GroupDRO + S0 FT` `0.806`). This suggests all-source auxiliary training helped outcome-style auxiliary tasks more than the phenotype readout objective.
- Transition smoothing remains beneficial for S7: macro F1 rises from encoder-only `0.730` to encoder+transition `0.769`, a gain of `0.040`.
- The low GPU utilization observed during training is consistent with a Python/DataLoader-heavy workload. The 8GPU path worked and completed, but speed is still constrained by data preparation and evaluation rather than raw GPU throughput.

## Visual Outputs
- `strategy_macro_f1_bar.png`
- `multi_metric_scatter.png`
- `method_ablation_macro_f1.png`
- `training_monitor_curves.png`
- `s7_source_mix_pie.png`
- `selected_strategy_radar.png`

## Data Files
- `s7_strategy_comparison_summary.csv`
- `s7_strategy_method_metrics.csv`
- `s7_strategy_training_history.csv`
- `s7_strategy_source_mix.csv`
