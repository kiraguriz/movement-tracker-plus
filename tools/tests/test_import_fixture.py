import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "import-fixture.sh"


class ImportFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.source = self.directory / "capture.jsonl"
        self.destination = self.directory / "real"
        self.header = {
            "format": "movement-tracker.pose",
            "version": 1,
            "exerciseSpecID": "squat.bodyweight",
            "cameraPosition": "front",
            "created": "2026-11-01T12:00:00Z",
            "frameCount": 2,
            "labels": {"tags": []},
        }
        self.body = (
            b'{"t":0,"joints":{},"imageAspect":0.5625}\n'
            b'{"t":0.0333,"joints":{},"imageAspect":0.5625}\n'
        )

    def write_capture(self):
        self.source.write_bytes(json.dumps(self.header).encode() + b"\n" + self.body)

    def run_import(self, *extra):
        return subprocess.run(
            [str(SCRIPT), str(self.source), "--reps", "0", "--dest", str(self.destination), *extra],
            capture_output=True,
            text=True,
            check=False,
        )

    def assert_rejected(self, message):
        result = self.run_import()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertFalse(self.destination.exists())

    def test_idle_capture_gets_human_labels_without_changing_frames_or_source(self):
        self.write_capture()
        original = self.source.read_bytes()
        result = self.run_import("--partials", "2", "--tag", "idle", "--tag", "person-a")
        self.assertEqual(result.returncode, 0, result.stderr)
        target = Path(result.stdout.strip())
        header, _, body = target.read_bytes().partition(b"\n")
        labels = json.loads(header)["labels"]
        self.assertEqual(labels["reps"], 0)
        self.assertEqual(labels["partials"], 2)
        self.assertEqual(labels["tags"], ["idle", "person-a", "verified"])
        self.assertEqual(body, self.body)
        self.assertEqual(self.source.read_bytes(), original)

    def test_old_algorithm_counts_are_replaced(self):
        self.header["labels"] = {"reps": 10, "partials": 0, "tags": []}
        self.write_capture()
        result = self.run_import()
        self.assertEqual(result.returncode, 0, result.stderr)
        header = json.loads(Path(result.stdout.strip()).read_bytes().splitlines()[0])
        self.assertEqual(header["labels"]["reps"], 0)

    def test_empty_or_interrupted_capture_is_not_verified(self):
        for count in (None, 0, 3):
            with self.subTest(frame_count=count):
                self.header["frameCount"] = count
                self.write_capture()
                self.assert_rejected("frame count")

    def test_corrupt_or_truncated_frames_are_not_verified(self):
        for body in (b"{broken\n", b'{"t":0.0', b"{}\n{}\n"):
            with self.subTest(body=body):
                self.body = body
                self.write_capture()
                self.assert_rejected("frame")

    def test_unknown_version_is_not_verified(self):
        self.header["version"] = 99
        self.write_capture()
        self.assert_rejected("version")

    def test_replay_is_never_imported_as_real(self):
        self.header["labels"]["tags"] = ["replay"]
        self.write_capture()
        self.assert_rejected("replayed")

    def test_invalid_label_shape_is_rejected_without_a_traceback(self):
        self.header["labels"] = {"tags": "idle"}
        self.write_capture()
        self.assert_rejected("tags")

    def test_existing_import_is_not_overwritten(self):
        self.write_capture()
        first = self.run_import()
        self.assertEqual(first.returncode, 0, first.stderr)
        target = Path(first.stdout.strip())
        original = target.read_bytes()
        again = self.run_import()
        self.assertNotEqual(again.returncode, 0)
        self.assertIn("already exists", again.stderr)
        self.assertEqual(target.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
