import hashlib
import importlib.util
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parent / "send_rog_remote_ops_command.py"
SPEC = importlib.util.spec_from_file_location("send_rog_remote_ops_command", SCRIPT_PATH)
sender = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(sender)


class RogRemoteOpsSenderTests(unittest.TestCase):
    def test_build_update_zip_uses_only_remote_ops_allowlist_entries(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            for relative_path in sender.UPDATE_FILES:
                path = root / relative_path
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(f"payload for {relative_path}\n", encoding="utf-8")

            blob, digest, entries = sender.build_update_zip(root)

        self.assertEqual(entries, sender.UPDATE_FILES)
        self.assertEqual(hashlib.sha256(blob).hexdigest(), digest)
        with zipfile.ZipFile(sender.io.BytesIO(blob)) as archive:
            names = archive.namelist()
            self.assertEqual(names, sender.UPDATE_FILES)
            self.assertFalse(any(name.endswith("/") for name in names))

    def test_build_update_zip_can_use_delivery_tree_fallbacks(self):
        with tempfile.TemporaryDirectory() as tmp_dir:
            delivery_root = Path(tmp_dir) / "delivery"
            bundle_root = delivery_root / "06_scripts" / "rog_actual_training_update"
            deploy_root = delivery_root / "03_remote_server_model_package" / "02_model_deploy_package" / "deploy"
            bundle_root.mkdir(parents=True)
            deploy_root.mkdir(parents=True)
            for relative_path in sender.UPDATE_FILES:
                if relative_path.startswith("deploy/"):
                    target = deploy_root / relative_path.removeprefix("deploy/")
                    target.write_text(f"deploy {target.name}\n", encoding="utf-8")
                elif relative_path.startswith("scripts/"):
                    target = bundle_root / Path(relative_path).name
                    target.write_text(f"script {target.name}\n", encoding="utf-8")
                else:
                    target = bundle_root / relative_path
                    target.write_text(f"bundle {target.name}\n", encoding="utf-8")

            blob, _digest, entries = sender.build_update_zip(bundle_root)

        self.assertEqual(entries, sender.UPDATE_FILES)
        with zipfile.ZipFile(sender.io.BytesIO(blob)) as archive:
            self.assertEqual(archive.read("deploy/model_service.py").decode("utf-8"), "deploy model_service.py\n")
            self.assertEqual(
                archive.read("scripts/update_rog_model_service.ps1").decode("utf-8"),
                "script update_rog_model_service.ps1\n",
            )


if __name__ == "__main__":
    unittest.main()
