import argparse
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

import release_provenance as subject


class ReleaseProvenanceTest(unittest.TestCase):
    repository = "JovieInc/symphony"
    source_sha = "a" * 40
    run_id = 12345
    run_attempt = 2

    def fixture(self):
        return {
            "main_ref": {"object": {"type": "commit", "sha": self.source_sha}},
            "workflow": {
                "id": 42,
                "path": subject.WORKFLOW_PATH,
                "name": "make-all",
                "state": "active",
            },
            "run": {
                "id": self.run_id,
                "run_attempt": self.run_attempt,
                "workflow_id": 42,
                "repository": {"full_name": self.repository},
                "head_repository": {"full_name": self.repository},
                "head_sha": self.source_sha,
                "head_branch": "main",
                "event": "push",
                "status": "completed",
                "conclusion": "success",
                "html_url": f"https://github.com/JovieInc/symphony/actions/runs/{self.run_id}",
            },
        }

    def validate(self, fixture):
        return subject.validate_ci(
            self.repository,
            self.source_sha,
            self.run_id,
            self.run_attempt,
            fixture["main_ref"],
            fixture["workflow"],
            fixture["run"],
        )

    def test_accepts_exact_successful_main_push(self):
        result = self.validate(self.fixture())
        self.assertEqual(result["source_sha"], self.source_sha)
        self.assertEqual(result["make_all"]["run_attempt"], self.run_attempt)

    def test_rejects_untrusted_ci_receipts(self):
        mutations = {
            "failed": lambda fixture: fixture["run"].update(conclusion="failure"),
            "stale": lambda fixture: fixture["main_ref"]["object"].update(sha="b" * 40),
            "foreign": lambda fixture: fixture["run"]["repository"].update(full_name="elsewhere/symphony"),
            "wrong event": lambda fixture: fixture["run"].update(event="pull_request"),
            "wrong attempt": lambda fixture: fixture["run"].update(run_attempt=3),
            "wrong workflow": lambda fixture: fixture["run"].update(workflow_id=99),
        }
        for label, mutate in mutations.items():
            with self.subTest(label=label):
                fixture = self.fixture()
                mutate(fixture)
                with self.assertRaises(subject.ProvenanceError):
                    self.validate(fixture)

    def test_release_is_repeatable_and_detects_mutation(self):
        with tempfile.TemporaryDirectory() as root:
            root_path = Path(root)
            input_path = root_path / "input"
            output_path = root_path / "output"
            for target in subject.TARGETS:
                artifact = f"symphony-{self.source_sha}-{target}"
                build = input_path / f"build-{target}"
                smoke = input_path / f"smoke-{target}"
                build.mkdir(parents=True)
                smoke.mkdir(parents=True)
                binary = build / artifact
                binary.write_text(f"binary for {target}\n", encoding="utf-8")
                artifact_digest = hashlib.sha256(binary.read_bytes()).hexdigest()
                (build / f"{artifact}.sha256").write_text(
                    f"{artifact_digest}  {artifact}\n", encoding="utf-8"
                )
                subject.write_json(
                    build / f"{artifact}.provenance.json",
                    {
                        "repository": self.repository,
                        "source_sha": self.source_sha,
                        "target": target,
                        "artifact": artifact,
                        "sha256": artifact_digest,
                        "make_all": {"run_id": self.run_id, "run_attempt": self.run_attempt},
                    },
                )
                subject.write_json(
                    smoke / f"{artifact}.smoke.json",
                    {
                        "repository": self.repository,
                        "source_sha": self.source_sha,
                        "target": target,
                        "artifact": artifact,
                        "sha256": artifact_digest,
                        "make_all_run_id": self.run_id,
                        "make_all_run_attempt": self.run_attempt,
                        "result": "passed",
                        "observed_exit_status": 1,
                    },
                )

            shared = {
                "repository": self.repository,
                "source_sha": self.source_sha,
                "run_id": self.run_id,
                "run_attempt": self.run_attempt,
            }
            subject.assemble(
                argparse.Namespace(input_dir=input_path, output_dir=output_path, **shared)
            )
            verify_args = argparse.Namespace(release_dir=output_path, **shared)
            subject.verify_release(verify_args)
            subject.verify_release(verify_args)

            (output_path / f"symphony-{self.source_sha}-linux_x86_64").write_text(
                "mutated", encoding="utf-8"
            )
            with self.assertRaises(subject.ProvenanceError):
                subject.verify_release(verify_args)


if __name__ == "__main__":
    unittest.main()
