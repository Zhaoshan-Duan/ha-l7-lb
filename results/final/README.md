# Final Experiment Results

Data bundle produced by Joshua for teammate's final report writing.

## Folder layout

```
results/final/
├── RUNS.md                 # Run command reference (what was executed)
├── SCREENSHOTS.md          # Screenshot capture checklist
├── HANDOFF.md              # Per-experiment data summary + caveats
├── exp1/
│   └── weighted_hetero_70_30/
│       ├── stats.csv
│       ├── stats_history.csv
│       ├── failures.csv
│       ├── report.html
│       ├── lb_snapshots/       # /metrics + /health/backends per LB task
│       └── screenshots/
├── exp2/
│   ├── retry_on_{50,100,200}/
│   └── retry_off_{50,100,200}/
└── exp3/
    └── lb{1,2,4,8}_{u500,u2000,spike}/
```

Each run folder has (roughly):
- `stats.csv` — Locust per-endpoint stats (RPS, p50, p95, p99, failures)
- `stats_history.csv` — 10-second snapshots throughout the run
- `failures.csv` — error-level details
- `report.html` — self-contained Locust HTML summary
- `lb_snapshots/` — LB metrics JSON (per-backend distribution) captured mid/end-run
- `screenshots/` — manual AWS Console captures per SCREENSHOTS.md

## How to use this bundle

1. Read `HANDOFF.md` for per-experiment summary tables and caveats.
2. Pull CSVs into your analysis tool of choice (Excel, pandas, R) for charts.
3. Attach screenshots inline where the report references the related finding.

## Reproducibility

All commands used to generate this data are in `RUNS.md`. Infrastructure
is defined in the repo's `terraform/` modules. S3 artifact bucket is
destroyed post-experiment (7-day lifecycle also applies).
