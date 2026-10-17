# Photometric-reference survival tables

Integer exhaustive reference, 1.5 px tolerance at each pyramid level. These are not percentages of semantically correct motion. Primary pair 4; fixed rectangles, not tracked surfaces.

| Window / region | Evaluable / sampled | Never evaluated L0 | Lost before synthesis | Lost in synthesis | Retained |
| --- | ---: | ---: | ---: | ---: | ---: |
| avatar69 / pan-background | 19/20 | 2/19 (10.5%) | 1/19 (5.3%) | 1/19 (5.3%) | 15/19 (78.9%) |
| avatar69 / crossing-bison | 19/20 | 10/19 (52.6%) | 1/19 (5.3%) | 1/19 (5.3%) | 7/19 (36.8%) |
| avatar69 / blur-foreground | 12/24 | 7/12 (58.3%) | 0/12 (0.0%) | 2/12 (16.7%) | 3/12 (25.0%) |
| avatar300 / face-contour | 15/20 | 15/15 (100.0%) | 0/15 (0.0%) | 0/15 (0.0%) | 0/15 (0.0%) |
| avatar300 / clothing-contour | 10/20 | 10/10 (100.0%) | 0/10 (0.0%) | 0/10 (0.0%) | 0/10 (0.0%) |
| anime1082 / bird-contour | 24/24 | 1/24 (4.2%) | 0/24 (0.0%) | 1/24 (4.2%) | 22/24 (91.7%) |
| anime1082 / landscape-pan | 17/20 | 2/17 (11.8%) | 0/17 (0.0%) | 1/17 (5.9%) | 14/17 (82.4%) |

## Consecutive-pair controls

Each row uses the same spatial rectangles. Region contents can move out of them. Do not average the scene-cut row into motion quality.

| Window | Pair | Evaluable | Never evaluated | Lost before synthesis | Lost in synthesis | Retained | Note |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| avatar69 | 2 | 45 | 20 | 3 | 5 | 17 | |
| avatar69 | 3 | 48 | 23 | 6 | 3 | 16 | |
| avatar69 | 4 | 50 | 19 | 2 | 4 | 25 | |
| avatar69 | 5 | 52 | 18 | 3 | 8 | 23 | |
| avatar69 | 6 | 42 | 18 | 2 | 5 | 17 | |
| avatar300 | 2 | 18 | 17 | 0 | 1 | 0 | |
| avatar300 | 3 | 21 | 8 | 2 | 4 | 7 | |
| avatar300 | 4 | 25 | 25 | 0 | 0 | 0 | |
| avatar300 | 5 | 31 | 10 | 4 | 11 | 6 | |
| avatar300 | 6 | 34 | 18 | 1 | 8 | 7 | |
| anime1082 | 2 | 41 | 3 | 2 | 2 | 34 | |
| anime1082 | 3 | 41 | 5 | 1 | 2 | 33 | |
| anime1082 | 4 | 41 | 3 | 0 | 2 | 36 | |
| anime1082 | 5 | 43 | 6 | 0 | 1 | 36 | |
| anime1082 | 6 | 28 | 28 | 0 | 0 | 0 | **Scene cut** |

## Primary pair, per-level references

References are independently searched at each level; these cohorts differ and must not be treated as survival of one fixed semantic trajectory across levels.

| Window | Level | Evaluable | Evaluated | Retained after aggregation | Loss events |
| --- | ---: | ---: | ---: | ---: | --- |
| avatar69 | 0 | 50 | 31 | 29 | {'densePatchAggregate': 1, 'densePatchPropagate': 2} |
| avatar69 | 1 | 61 | 42 | 37 | {'densePatchAggregate': 5, 'densePatchSearch': 3, 'densePatchPropagate': 4} |
| avatar69 | 2 | 62 | 46 | 42 | {'densePatchAggregate': 3, 'densePatchSearch': 3, 'densePatchPropagate': 4, 'densePatchTemporalSelect': 2} |
| avatar69 | 3 | 62 | 53 | 44 | {'densePatchAggregate': 8, 'densePatchPropagate': 2} |
| avatar300 | 0 | 25 | 0 | 0 | {} |
| avatar300 | 1 | 26 | 0 | 0 | {} |
| avatar300 | 2 | 26 | 0 | 0 | {} |
| avatar300 | 3 | 26 | 1 | 1 | {} |
| anime1082 | 0 | 41 | 38 | 38 | {} |
| anime1082 | 1 | 44 | 42 | 42 | {} |
| anime1082 | 2 | 44 | 44 | 43 | {'densePatchSearch': 1, 'densePatchPropagate': 2, 'densePatchTemporalSelect': 1} |
| anime1082 | 3 | 44 | 44 | 44 | {} |
