import hashlib
import hmac
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parent / "verify_artifact_bundle.py"
SPEC = importlib.util.spec_from_file_location("sepsiscare_verify_artifact_bundle_under_test", MODULE_PATH)
verify_artifact_bundle = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(verify_artifact_bundle)


class VerifyArtifactBundleTests(unittest.TestCase):
    def write_bundle(self, path: Path, files: dict[str, bytes], key: str = "") -> None:
        manifest = "".join(
            f"{hashlib.sha256(content).hexdigest()}  {name}\n"
            for name, content in sorted(files.items())
        )
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name, content in files.items():
                archive.writestr(name, content)
            archive.writestr("MANIFEST.sha256", manifest)
            if key:
                archive.writestr(
                    "MANIFEST.sha256.hmac",
                    json.dumps(
                        {
                            "algorithm": "HMAC-SHA256",
                            "signed": "MANIFEST.sha256",
                            "signature": hmac.new(key.encode("utf-8"), manifest.encode("utf-8"), hashlib.sha256).hexdigest(),
                        },
                        sort_keys=True,
                    )
                    + "\n",
                )

    def test_verifies_manifest_hashes(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            bundle = Path(tmp_dir) / "artifact.zip"
            self.write_bundle(bundle, {"reports/summary.txt": b"ok"})

            result = verify_artifact_bundle.verify_bundle(bundle)

        self.assertEqual(result["files_verified"], 1)
        self.assertFalse(result["hmac_verified"])

    def test_rejects_tampered_manifest_entry(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            bundle = Path(tmp_dir) / "artifact.zip"
            manifest = f"{'0' * 64}  reports/summary.txt\n"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("reports/summary.txt", b"ok")
                archive.writestr("MANIFEST.sha256", manifest)

            with self.assertRaisesRegex(verify_artifact_bundle.ArtifactVerificationError, "sha256 mismatch"):
                verify_artifact_bundle.verify_bundle(bundle)

    def test_verifies_hmac_signature_when_key_is_supplied(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            bundle = Path(tmp_dir) / "artifact.zip"
            self.write_bundle(bundle, {"models/model.json": b"{}"}, key="release-key")

            result = verify_artifact_bundle.verify_bundle(bundle, hmac_key="release-key")

        self.assertTrue(result["hmac_verified"])

    def test_rejects_hmac_signature_mismatch(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            bundle = Path(tmp_dir) / "artifact.zip"
            self.write_bundle(bundle, {"models/model.json": b"{}"}, key="release-key")

            with self.assertRaisesRegex(verify_artifact_bundle.ArtifactVerificationError, "hmac mismatch"):
                verify_artifact_bundle.verify_bundle(bundle, hmac_key="wrong-key")

    def test_accepts_windows_manifest_separators(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            bundle = Path(tmp_dir) / "artifact.zip"
            content = b"checkpoint"
            manifest = f"{hashlib.sha256(content).hexdigest()}  models\\checkpoints\\best.pt\n"
            with zipfile.ZipFile(bundle, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("models/checkpoints/best.pt", content)
                archive.writestr("MANIFEST.sha256", manifest)

            result = verify_artifact_bundle.verify_bundle(bundle)

        self.assertEqual(result["files_verified"], 1)


if __name__ == "__main__":
    unittest.main()
