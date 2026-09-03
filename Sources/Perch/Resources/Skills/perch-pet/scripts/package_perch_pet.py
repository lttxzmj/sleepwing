#!/usr/bin/env python3
"""Validate and package a Perch v2 animated pet using macOS system tools."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ID_PATTERN = re.compile(r"^[a-z0-9_-]{1,64}$")
MAX_MANIFEST_BYTES = 128 * 1024
MAX_SPRITESHEET_BYTES = 20 * 1024 * 1024
MAX_PREVIEW_BYTES = 20 * 1024 * 1024
EXPECTED_WIDTH = 1536
EXPECTED_HEIGHT = 2288
EXPECTED_CELL_WIDTH = 192
EXPECTED_CELL_HEIGHT = 208
EXPECTED_COLUMNS = 8
EXPECTED_ROWS = 11


class PackageError(RuntimeError):
    pass


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Validate a completed v2 pet and create an importable .perchpet folder."
    )
    parser.add_argument("--source", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--print-contract", action="store_true")
    parser.add_argument("--visual-qa-report", type=Path)
    parser.add_argument("--require-visual-qa", action="store_true")
    return parser.parse_args()


def reject_symlink(path: Path, label: str) -> None:
    if path.is_symlink():
        raise PackageError(f"{label} must not be a symbolic link: {path}")


def image_properties(path: Path) -> dict[str, str]:
    result = subprocess.run(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", "-g", "hasAlpha", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise PackageError(f"macOS could not inspect the spritesheet: {result.stderr.strip()}")
    properties: dict[str, str] = {}
    for line in result.stdout.splitlines():
        if ":" not in line:
            continue
        key, value = line.strip().split(":", 1)
        properties[key.strip()] = value.strip()
    return properties


def contract_summary() -> dict[str, object]:
    return {
        "contract": "perch-motion-v2",
        "spriteVersionNumber": 2,
        "atlas": {
            "width": EXPECTED_WIDTH,
            "height": EXPECTED_HEIGHT,
            "columns": EXPECTED_COLUMNS,
            "rows": EXPECTED_ROWS,
            "cellWidth": EXPECTED_CELL_WIDTH,
            "cellHeight": EXPECTED_CELL_HEIGHT,
            "alphaRequired": True,
        },
    }


def validate_visual_qa_report(report_path: Path | None) -> dict[str, object]:
    if report_path is None:
        return {
            "status": "unverified",
            "note": "The packager performed structural checks only; no visual QA report was supplied.",
        }

    report_path = report_path.expanduser()
    reject_symlink(report_path, "visual QA report")
    report_path = report_path.resolve()
    if not report_path.is_file():
        raise PackageError(f"visual QA report is missing: {report_path}")
    if report_path.stat().st_size > MAX_MANIFEST_BYTES:
        raise PackageError("visual QA report exceeds 128 KB")
    try:
        report = json.loads(report_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageError(f"visual QA report is invalid: {error}") from error
    if not isinstance(report, dict) or report.get("ok") is not True:
        raise PackageError("visual QA report must contain ok: true")

    host_review = all(
        report.get(key) is True
        for key in (
            "contactSheetReviewed",
            "motionPreviewsReviewed",
            "directionsReviewed",
        )
    )
    hatch_review = all(
        isinstance(report.get(key), str) and bool(report.get(key))
        for key in (
            "contact_sheet",
            "direction_semantics",
            "review",
            "validation",
        )
    )
    if not host_review and not hatch_review:
        raise PackageError(
            "visual QA report lacks required host-review checks or hatch-pet evidence"
        )

    digest = hashlib.sha256(report_path.read_bytes()).hexdigest()
    return {
        "status": "passed",
        "evidenceType": "hatch-pet-run-summary" if hatch_review else "host-review",
        "evidenceFile": report_path.name,
        "evidenceSHA256": digest,
    }


def validate(
    source: Path,
    visual_qa: dict[str, object],
) -> tuple[dict[str, object], Path, dict[str, object]]:
    if not source.is_dir():
        raise PackageError(f"source is not a directory: {source}")
    reject_symlink(source, "source")

    manifest_path = source / "pet.json"
    if not manifest_path.is_file():
        raise PackageError("source does not contain pet.json")
    reject_symlink(manifest_path, "pet.json")
    if manifest_path.stat().st_size > MAX_MANIFEST_BYTES:
        raise PackageError("pet.json exceeds 128 KB")

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PackageError(f"pet.json is invalid: {error}") from error

    pet_id = manifest.get("id")
    if not isinstance(pet_id, str) or not ID_PATTERN.fullmatch(pet_id):
        raise PackageError("id must use 1–64 lowercase letters, digits, hyphens, or underscores")
    display_name = manifest.get("displayName")
    if not isinstance(display_name, str) or not display_name.strip():
        raise PackageError("displayName must not be empty")
    if len(display_name) > 64:
        raise PackageError("displayName must be 64 characters or fewer")
    description = manifest.get("description")
    if not isinstance(description, str) or len(description) > 240:
        raise PackageError("description must be a string of 240 characters or fewer")
    if manifest.get("spriteVersionNumber") != 2:
        raise PackageError("spriteVersionNumber must be 2")

    spritesheet_name = manifest.get("spritesheetPath")
    if not isinstance(spritesheet_name, str):
        raise PackageError("spritesheetPath must be a PNG or WebP file name")
    relative_path = Path(spritesheet_name)
    if (
        relative_path.name != spritesheet_name
        or relative_path.suffix.lower() not in {".png", ".webp"}
    ):
        raise PackageError("spritesheetPath must be a PNG or WebP file inside the package")

    spritesheet_path = source / spritesheet_name
    if not spritesheet_path.is_file():
        raise PackageError(f"spritesheet is missing: {spritesheet_name}")
    reject_symlink(spritesheet_path, "spritesheet")
    spritesheet_bytes = spritesheet_path.stat().st_size
    if spritesheet_bytes > MAX_SPRITESHEET_BYTES:
        raise PackageError("spritesheet exceeds 20 MB")

    properties = image_properties(spritesheet_path)
    if int(properties.get("pixelWidth", "0")) != EXPECTED_WIDTH:
        raise PackageError(f"spritesheet width must be {EXPECTED_WIDTH} pixels")
    if int(properties.get("pixelHeight", "0")) != EXPECTED_HEIGHT:
        raise PackageError(f"spritesheet height must be {EXPECTED_HEIGHT} pixels")
    if properties.get("hasAlpha", "").lower() != "yes":
        raise PackageError("spritesheet must contain an alpha channel")

    summary: dict[str, object] = {
        "ok": True,
        **contract_summary(),
        "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "checks": {
            "manifest": "pass",
            "spriteVersionNumber": 2,
            "pixelWidth": EXPECTED_WIDTH,
            "pixelHeight": EXPECTED_HEIGHT,
            "hasAlpha": True,
            "spritesheetBytes": spritesheet_bytes,
        },
        "visualQA": visual_qa,
    }
    return manifest, spritesheet_path, summary


def package(
    source: Path,
    output: Path,
    manifest: dict[str, object],
    spritesheet_path: Path,
    summary: dict[str, object],
) -> None:
    if output.suffix != ".perchpet":
        raise PackageError("output directory name must end in .perchpet")
    if output.exists():
        raise PackageError(f"output already exists; choose a new path: {output}")
    output.parent.mkdir(parents=True, exist_ok=True)

    temp_parent = Path(tempfile.mkdtemp(prefix=".perchpet-", dir=output.parent))
    staged = temp_parent / output.name
    try:
        staged.mkdir()
        (staged / "pet.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        shutil.copy2(spritesheet_path, staged / spritesheet_path.name)
        for preview_name in ("preview.webp", "preview.png"):
            preview = source / preview_name
            if preview.is_file() and not preview.is_symlink():
                if preview.stat().st_size > MAX_PREVIEW_BYTES:
                    raise PackageError("preview exceeds 20 MB")
                shutil.copy2(preview, staged / preview_name)
                break
        (staged / "qa-summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(staged, output)
    finally:
        shutil.rmtree(temp_parent, ignore_errors=True)


def main() -> int:
    args = parse_args()
    try:
        if args.print_contract:
            print(json.dumps(contract_summary(), sort_keys=True))
            return 0
        if args.source is None:
            raise PackageError("--source is required unless --print-contract is used")
        if not args.check_only and args.output is None:
            raise PackageError("--output is required unless --check-only is used")
        if args.check_only and args.output is not None:
            raise PackageError("--output cannot be combined with --check-only")
        if args.require_visual_qa and args.visual_qa_report is None:
            raise PackageError("--require-visual-qa needs --visual-qa-report")

        source = args.source.expanduser()
        reject_symlink(source, "source")
        source = source.resolve()
        visual_qa = validate_visual_qa_report(args.visual_qa_report)
        manifest, spritesheet_path, summary = validate(source, visual_qa)
        if args.require_visual_qa and visual_qa.get("status") != "passed":
            raise PackageError("visual QA did not pass")
        if args.check_only:
            print(json.dumps(summary, sort_keys=True))
            return 0

        output = args.output.expanduser().absolute()
        package(source, output, manifest, spritesheet_path, summary)
    except (PackageError, OSError, ValueError) as error:
        print(f"error={error}", file=sys.stderr)
        return 1
    print(f"perchpet_path={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
