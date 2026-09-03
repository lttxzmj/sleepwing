# Perch animated pet package

## Deliverable

Create a directory named `<pet-id>.perchpet`:

```text
<pet-id>.perchpet/
├── pet.json
├── spritesheet.webp
├── preview.webp       # optional
└── qa-summary.json    # created by the packager
```

`pet.json`:

```json
{
  "id": "lowercase-pet-id",
  "displayName": "Friendly name",
  "description": "One short sentence",
  "spriteVersionNumber": 2,
  "spritesheetPath": "spritesheet.webp"
}
```

## Structural contract

- Platform: Perch for macOS.
- Atlas: PNG or WebP with transparency.
- Exact dimensions: 1536 × 2288 pixels.
- Grid: 8 columns × 11 rows.
- Cell: 192 × 208 pixels.
- Maximum manifest size: 128 KB.
- Maximum atlas size: 20 MB.
- `id`: 1–64 lowercase letters, digits, hyphens, or underscores.
- `displayName`: non-empty and no more than 64 characters.
- `description`: a string no longer than 240 characters.
- `spritesheetPath`: a file name inside the package, with no directory traversal.

## Animation rows

| Row | Meaning | Used frames |
|---:|---|---:|
| 0 | calm idle loop | 6 |
| 1 | dragged toward screen-right | 8 |
| 2 | dragged toward screen-left | 8 |
| 3 | greeting / waving | 4 |
| 4 | success / jumping | 5 |
| 5 | failed / blocked | 8 |
| 6 | waiting for the user | 6 |
| 7 | actively working | 6 |
| 8 | reviewing / checking | 6 |
| 9 | look 000° through 157.5° | 8 |
| 10 | look 180° through 337.5° | 8 |

Look directions advance clockwise in 22.5-degree steps. `000` is up, `090` is screen-right, `180` is down, and `270` is screen-left.

## Visual acceptance

- The same character identity, proportions, palette, material, markings, and props persist across every row.
- Every used frame is non-empty, separated, and fully inside its cell.
- Unused cells are transparent.
- Idle contains visible but quiet micro-motion.
- Working does not mean literal foot-running.
- Waiting is visibly distinct from idle and review.
- Directional drag rows face and travel in the correct screen direction.
- Cardinal look directions are unmistakable at normal desktop-pet size.
- The 16 look frames form one continuous loop without reversals, jumps, scale pops, or detached features.
- No text, UI, guide marks, scenery, floor shadows, glow, speed lines, or detached effects appear in the sprite.

Structural validation cannot prove animation quality. Always inspect a contact sheet and motion previews before packaging.

## Deterministic gates

Print the packager's authoritative machine-readable contract:

```bash
python3 scripts/package_perch_pet.py --print-contract
```

Check a candidate without creating a package:

```bash
python3 scripts/package_perch_pet.py \
  --source /absolute/path/to/candidate \
  --check-only
```

Complete production requires a visual QA report. A non-Codex host report must contain `ok: true` plus `contactSheetReviewed`, `motionPreviewsReviewed`, and `directionsReviewed` set to `true` only after actual inspection. A passing hatch-pet `qa/run-summary.json` is also accepted when it contains its contact-sheet, direction-semantics, review, and deterministic-validation evidence.

```bash
python3 scripts/package_perch_pet.py \
  --source /absolute/path/to/candidate \
  --visual-qa-report /absolute/path/to/visual-qa.json \
  --require-visual-qa \
  --output /absolute/path/to/pet-id.perchpet
```
