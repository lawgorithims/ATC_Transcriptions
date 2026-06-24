# Airport Feed Configs

JSON files defining LiveATC streams and airport context for the live pipeline.

| File | Airport | Default feed |
|------|---------|--------------|
| `kdfw.json` | Dallas/Fort Worth (KDFW) | Lone Star Approach 17/35C Final |
| `kjfk.json` | New York JFK (KJFK) | Tower (legacy sample data) |

## KDFW streams (`kdfw.json`)

| Key | Label | Frequency |
|-----|-------|-----------|
| `lone_star_approach_17c_final` | Lone Star Approach (17/35C Final) | 127.075 |
| `lone_star_approach_17l_final` | Lone Star Approach (17L/35R Final) | 127.250 |
| `lone_star_approach_18r_final` | Lone Star Approach (18R/36L Final) | 125.150 |
| `tower_east` | KDFW Tower (East) | 126.550 |

```bash
python live_atc_pipeline.py --feed-config airport_configs/kdfw.json --feed lone_star_approach_17c_final
```

Replace the `url` in any stream entry to point at a different live feed.
