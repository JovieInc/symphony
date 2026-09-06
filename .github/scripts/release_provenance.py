#!/usr/bin/env python3
"""Validate and assemble immutable Symphony release provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


WORKFLOW_PATH = ".github/workflows/make-all.yml"
TARGETS = ("linux_x86_64", "linux_arm64", "macos_x86_64", "macos_arm64")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


class ProvenanceError(ValueError):
    pass


def load_json(path: str | Path) -> dict:
    with Path(path).open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ProvenanceError(f"{path} must contain a JSON object")
    return value


def write_json(path: str | Path, value: dict) -> None:
    Path(path).write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def digest(path: str | Path) -> str:
    result = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ProvenanceError(message)


def validate_ci(
    repository: str,
    source_sha: str,
    run_id: int,
    run_attempt: int,
    main_ref: dict,
    workflow: dict,
    run: dict,
) -> dict:
    require(repository == "JovieInc/symphony", "unexpected repository")
    require(bool(SHA_RE.fullmatch(source_sha)), "source SHA must be 40 lowercase hex characters")
    require(main_ref.get("object", {}).get("type") == "commit", "main must resolve to a commit")
    require(main_ref.get("object", {}).get("sha") == source_sha, "source SHA is not current main")
    require(workflow.get("path") == WORKFLOW_PATH, "unexpected make-all workflow path")
    require(workflow.get("name") == "make-all", "unexpected make-all workflow name")
    require(workflow.get("state") == "active", "make-all workflow is not active")
    require(run.get("id") == run_id, "make-all run ID mismatch")
    require(run.get("run_attempt") == run_attempt, "make-all run attempt mismatch")
    require(run.get("workflow_id") == workflow.get("id"), "make-all workflow ID mismatch")
    require(run.get("repository", {}).get("full_name") == repository, "foreign repository run")
    head_repository = run.get("head_repository")
    require(
        head_repository is None or head_repository.get("full_name") == repository,
        "foreign head repository run",
    )
    require(run.get("head_sha") == source_sha, "make-all run head SHA mismatch")
    require(run.get("head_branch") == "main", "make-all run is not for main")
    require(run.get("event") == "push", "make-all run is not a push event")
    require(run.get("status") == "completed", "make-all run is not complete")
    require(run.get("conclusion") == "success", "make-all run did not succeed")

    return {
        "repository": repository,
        "source_sha": source_sha,
        "make_all": {
            "workflow_id": workflow["id"],
            "workflow_path": WORKFLOW_PATH,
            "run_id": run_id,
            "run_attempt": run_attempt,
            "event": "push",
            "conclusion": "success",
            "url": run.get("html_url"),
        },
    }


def expected_names(source_sha: str) -> set[str]:
    names = {
        f"symphony-{source_sha}-manifest.json",
        f"symphony-{source_sha}-manifest.json.sha256",
    }
    for target in TARGETS:
        artifact = f"symphony-{source_sha}-{target}"
        names.update(
            {
                artifact,
                f"{artifact}.sha256",
                f"{artifact}.provenance.json",
                f"{artifact}.smoke.json",
            }
        )
    return names


def validate_target_files(
    directory: Path, repository: str, source_sha: str, run_id: int, run_attempt: int, target: str
) -> dict:
    artifact = f"symphony-{source_sha}-{target}"
    artifact_path = directory / artifact
    digest_path = directory / f"{artifact}.sha256"
    provenance_path = directory / f"{artifact}.provenance.json"
    smoke_path = directory / f"{artifact}.smoke.json"
    for path in (artifact_path, digest_path, provenance_path, smoke_path):
        require(path.is_file(), f"missing release asset {path.name}")

    artifact_digest = digest(artifact_path)
    digest_fields = digest_path.read_text(encoding="utf-8").strip().split()
    require(digest_fields == [artifact_digest, artifact], f"invalid digest file for {artifact}")

    provenance = load_json(provenance_path)
    require(provenance.get("repository") == repository, f"repository mismatch for {artifact}")
    require(provenance.get("source_sha") == source_sha, f"source SHA mismatch for {artifact}")
    require(provenance.get("target") == target, f"target mismatch for {artifact}")
    require(provenance.get("artifact") == artifact, f"artifact name mismatch for {artifact}")
    require(provenance.get("sha256") == artifact_digest, f"artifact digest mismatch for {artifact}")
    make_all = provenance.get("make_all", {})
    require(make_all.get("run_id") == run_id, f"make-all run ID mismatch for {artifact}")
    require(make_all.get("run_attempt") == run_attempt, f"make-all attempt mismatch for {artifact}")

    smoke = load_json(smoke_path)
    require(smoke.get("repository") == repository, f"smoke repository mismatch for {artifact}")
    require(smoke.get("source_sha") == source_sha, f"smoke source SHA mismatch for {artifact}")
    require(smoke.get("target") == target, f"smoke target mismatch for {artifact}")
    require(smoke.get("artifact") == artifact, f"smoke artifact mismatch for {artifact}")
    require(smoke.get("sha256") == artifact_digest, f"smoke digest mismatch for {artifact}")
    require(smoke.get("make_all_run_id") == run_id, f"smoke run ID mismatch for {artifact}")
    require(smoke.get("make_all_run_attempt") == run_attempt, f"smoke attempt mismatch for {artifact}")
    require(smoke.get("result") == "passed", f"smoke did not pass for {artifact}")
    require(smoke.get("observed_exit_status") == 1, f"unexpected smoke exit for {artifact}")

    return {
        "target": target,
        "artifact": artifact,
        "sha256": artifact_digest,
        "digest_file": digest_path.name,
        "provenance_file": provenance_path.name,
        "smoke_receipt_file": smoke_path.name,
    }


def assemble(args: argparse.Namespace) -> None:
    source = Path(args.input_dir)
    output = Path(args.output_dir)
    output.mkdir(parents=True, exist_ok=True)
    for target in TARGETS:
        artifact = f"symphony-{args.source_sha}-{target}"
        source_paths = (
            source / f"build-{target}" / artifact,
            source / f"build-{target}" / f"{artifact}.sha256",
            source / f"build-{target}" / f"{artifact}.provenance.json",
            source / f"smoke-{target}" / f"{artifact}.smoke.json",
        )
        for path in source_paths:
            require(path.is_file(), f"missing workflow artifact {path}")
            shutil.copy2(path, output / path.name)

    artifacts = [
        validate_target_files(
            output,
            args.repository,
            args.source_sha,
            args.run_id,
            args.run_attempt,
            target,
        )
        for target in TARGETS
    ]
    manifest = {
        "schema_version": 1,
        "repository": args.repository,
        "source_sha": args.source_sha,
        "make_all": {
            "workflow_path": WORKFLOW_PATH,
            "run_id": args.run_id,
            "run_attempt": args.run_attempt,
            "event": "push",
            "conclusion": "success",
        },
        "artifacts": artifacts,
    }
    manifest_path = output / f"symphony-{args.source_sha}-manifest.json"
    write_json(manifest_path, manifest)
    manifest_digest = digest(manifest_path)
    (output / f"{manifest_path.name}.sha256").write_text(
        f"{manifest_digest}  {manifest_path.name}\n", encoding="utf-8"
    )


def verify_release(args: argparse.Namespace) -> None:
    directory = Path(args.release_dir)
    actual_names = {path.name for path in directory.iterdir() if path.is_file()}
    require(actual_names == expected_names(args.source_sha), "release asset set mismatch")

    manifest_path = directory / f"symphony-{args.source_sha}-manifest.json"
    manifest_digest_path = directory / f"{manifest_path.name}.sha256"
    manifest_digest = digest(manifest_path)
    require(
        manifest_digest_path.read_text(encoding="utf-8").strip().split()
        == [manifest_digest, manifest_path.name],
        "manifest digest mismatch",
    )
    manifest = load_json(manifest_path)
    require(manifest.get("schema_version") == 1, "unsupported manifest schema")
    require(manifest.get("repository") == args.repository, "manifest repository mismatch")
    require(manifest.get("source_sha") == args.source_sha, "manifest source SHA mismatch")
    make_all = manifest.get("make_all", {})
    require(make_all.get("workflow_path") == WORKFLOW_PATH, "manifest workflow mismatch")
    require(make_all.get("run_id") == args.run_id, "manifest run ID mismatch")
    require(make_all.get("run_attempt") == args.run_attempt, "manifest attempt mismatch")
    require(make_all.get("event") == "push", "manifest event mismatch")
    require(make_all.get("conclusion") == "success", "manifest conclusion mismatch")

    expected_artifacts = [
        validate_target_files(
            directory,
            args.repository,
            args.source_sha,
            args.run_id,
            args.run_attempt,
            target,
        )
        for target in TARGETS
    ]
    require(manifest.get("artifacts") == expected_artifacts, "manifest artifact inventory mismatch")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    verify_ci_parser = subparsers.add_parser("verify-ci")
    verify_ci_parser.add_argument("--repository", required=True)
    verify_ci_parser.add_argument("--source-sha", required=True)
    verify_ci_parser.add_argument("--run-id", required=True, type=int)
    verify_ci_parser.add_argument("--run-attempt", required=True, type=int)
    verify_ci_parser.add_argument("--main-ref-json", required=True)
    verify_ci_parser.add_argument("--workflow-json", required=True)
    verify_ci_parser.add_argument("--run-json", required=True)
    verify_ci_parser.add_argument("--output", required=True)

    for command in ("assemble", "verify-release"):
        command_parser = subparsers.add_parser(command)
        command_parser.add_argument("--repository", required=True)
        command_parser.add_argument("--source-sha", required=True)
        command_parser.add_argument("--run-id", required=True, type=int)
        command_parser.add_argument("--run-attempt", required=True, type=int)
        if command == "assemble":
            command_parser.add_argument("--input-dir", required=True)
            command_parser.add_argument("--output-dir", required=True)
        else:
            command_parser.add_argument("--release-dir", required=True)

    return parser.parse_args()


def main() -> int:
    try:
        args = parse_args()
        if args.command == "verify-ci":
            result = validate_ci(
                args.repository,
                args.source_sha,
                args.run_id,
                args.run_attempt,
                load_json(args.main_ref_json),
                load_json(args.workflow_json),
                load_json(args.run_json),
            )
            write_json(args.output, result)
        elif args.command == "assemble":
            assemble(args)
        else:
            verify_release(args)
    except (OSError, json.JSONDecodeError, ProvenanceError) as error:
        print(f"release provenance rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
