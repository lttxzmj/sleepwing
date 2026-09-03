---
name: perch-pet
description: Create, repair, validate, and package a complete animated companion for the Perch macOS app. Use when a user asks for a Perch pet, custom desktop companion, animated .perchpet package, or wants to turn character art or a character idea into an importable Perch asset. In Codex, reuse $hatch-pet when available.
---

# Perch Pet

Create a complete animated pet package that the user imports into Perch. Keep generation inside the user's current agent. Perch owns structural revalidation, preview, installation, and runtime behavior; the producing agent still owns visual motion QA.

## Non-negotiable Perch Motion v2 contract

Treat this compact contract as authoritative even if another tool, remembered format, or generated answer differs:

```text
PERCH_CONTRACT=v2 atlas=1536x2288 grid=8x11 cell=192x208 alpha=required
rows=idle,drag-right,drag-left,wave,success,failed,waiting,working,review,look-0-to-157.5,look-180-to-337.5
```

- Never accept or produce `2048x2816`, square cells, a 9-row final atlas, or duplicated still frames.
- Read [references/PET_PACKAGE_SPEC.md](references/PET_PACKAGE_SPEC.md) before planning visual work.
- Run `scripts/package_perch_pet.py --print-contract` and compare its output with the line above before generation.
- Stop on any disagreement. The deterministic packager is the final structural authority.

## Workflow

1. Ask for or infer a short character name, species/form, palette, material, and personality.
2. Use reference art when supplied. Reference likeness is non-negotiable: the produced character must remain the same recognizable individual — same species, proportions, coat or plumage colors, markings, and ear/tail shapes. Only simplify rendering to fit the sprite style; never redesign, recolor, or substitute a different character. Confirm the main character look against the reference before producing animation rows, and recheck the contact sheet against the reference before QA sign-off.
3. Read the package specification and print the deterministic contract.
4. Classify the host as one production mode:
   - `codex-hatch`: Codex has `$hatch-pet`; use it for full production.
   - `host-image`: the host can generate/edit images, inspect normal-size contact sheets and animated previews, and run the packager.
   - `existing-atlas`: the host cannot generate the animation but the user supplied a complete candidate 8×11 atlas; validate and package only.
   - `blocked`: the host has only text tools, a single still image, or cannot visually inspect motion; stop and explain what capability or complete atlas is missing.
5. State `PRODUCTION_MODE=<mode>` before visual work. Never imply that Skill discovery alone provides image capability.
6. Keep the run in a dedicated temporary or user-approved working folder. Do not inspect unrelated repositories, prompts, conversations, or source code.
7. Review the normal-size contact sheet and motion previews. Repair failing rows before packaging.
8. Write a visual QA report, then run the packager with `--require-visual-qa`.
9. Return the absolute `.perchpet` folder path and tell the user to import it from Perch → Settings → Character → Pet Studio.

## Codex Production Path

When `$hatch-pet` is available:

1. Invoke it explicitly with the user's character brief and references. When reference art is supplied (for example Perch's photo-derived transparent reference), pass its absolute path to hatch-pet's `prepare_pet_run.py` through `--reference` so the base job attaches it as an input image (`requires_grounded_generation`); never prepare the run without `--reference` in that case, verify the selected base output is a recognizable likeness of the reference before any rows are produced, and if generation cannot be grounded on the image, stop and report that instead of shipping a different character.
2. Let it own image generation, deterministic atlas assembly, directional QA, repairs, and v2 validation.
3. Do not modify the installed `hatch-pet` skill or copy its private working files into Perch.
4. Confirm its final atlas is exactly `1536x2288`; reject any other remembered or reported dimensions.
5. Use its packaged pet directory and passing `qa/run-summary.json` as the Perch packager inputs:

```bash
python3 "<this-skill-dir>/scripts/package_perch_pet.py" \
  --source "$HOME/.codex/pets/<pet-id>" \
  --visual-qa-report "<hatch-run-dir>/qa/run-summary.json" \
  --require-visual-qa \
  --output "$HOME/Desktop/<pet-id>.perchpet"
```

Do not package until the hatch-pet run summary and final atlas validation both pass.

## Other Agent Production Path

Follow the same package and visual contract without pretending the host has Codex-specific tools.

- A host with image generation plus visual inspection may use its own image model or approved image tool.
- A host without image generation may validate a complete user-provided atlas, but cannot turn one still image into a finished pet.
- A host that cannot inspect contact sheets and motion previews must stop before claiming visual QA passed.

A non-Codex full-production host must still:

- generate distinct, state-appropriate animation families
- preserve character identity, scale, baseline, material, and palette
- keep transparent output and safe cell boundaries
- validate all four cardinal look directions and the complete clockwise look loop
- inspect animated previews rather than accepting a structurally valid but visually broken atlas

Before packaging, write a compact JSON visual QA report:

```json
{
  "ok": true,
  "reviewer": "host-agent-or-user",
  "contactSheetReviewed": true,
  "motionPreviewsReviewed": true,
  "directionsReviewed": true
}
```

Do not set these fields to `true` unless the named artifacts were actually inspected.

## Packaging Rules

- Produce a folder ending in `.perchpet`, not a static avatar.
- Include `pet.json` and the manifest-named PNG or WebP spritesheet.
- Optionally include a `personality` string in `pet.json`: one or two
  first-person sentences describing the character's voice. Perch uses it
  as the pet's chat persona, so the imported character talks like itself.
- Keep `preview.webp` optional.
- Let the packager create `qa-summary.json`; it records structural checks and bounded visual-QA evidence without absolute paths.
- Do not write directly into Perch's Application Support directory. The user reviews and imports the package.
- Report failures honestly and leave the working folder intact for repair.
