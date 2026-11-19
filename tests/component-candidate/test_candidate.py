"""Exercise candidate preparation against isolated, local Git repositories."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


MAKEFILE = Path(__file__).resolve().parents[2] / "Makefile"
CONSUMERS = {
    "kaster": "charts/kaster",
    "summon": "charts/summon",
    "microspell": "charts/trinkets/microspell",
    "tarot": "charts/trinkets/tarot",
    "covenant": "covenant",
}


class CandidateFixture:
    def __init__(self, directory):
        self.root = Path(directory)
        self.checkout = self.root / "runik"
        self.checkout.mkdir()
        self.env = {
            **os.environ,
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_ALLOW_PROTOCOL": "file",
            "GIT_AUTHOR_NAME": "Candidate test",
            "GIT_AUTHOR_EMAIL": "candidate@example.invalid",
            "GIT_COMMITTER_NAME": "Candidate test",
            "GIT_COMMITTER_EMAIL": "candidate@example.invalid",
            "TERM": "dumb",
        }
        for name in ("MAKEFLAGS", "MFLAGS", "MAKELEVEL"):
            self.env.pop(name, None)
        self.source = self.root / "glyphs-origin"
        self.git(self.root, "init", "--quiet", "--initial-branch=upstream", str(self.source))
        self.old = self.commit_glyphs("old")
        self.candidate = self.commit_glyphs("candidate")
        self.latest = self.commit_glyphs("latest")
        self.git(self.source, "checkout", "--quiet", "-b", "unmerged", self.candidate)
        self.unmerged = self.commit_glyphs("unmerged")
        self.git(self.source, "checkout", "--quiet", "upstream")
        self.canonical = self.checkout / "charts/glyphs"
        self.clone_glyphs(self.canonical)
        for path in CONSUMERS.values():
            parent = self.checkout / path
            parent.mkdir(parents=True, exist_ok=True)
            self.git(parent, "init", "--quiet", "--initial-branch=upstream")
            self.clone_glyphs(parent / "charts")
            self.pin(parent, self.old)
        self.component = "kaster"

    def run(self, args, cwd, check=True):
        result = subprocess.run(args, cwd=cwd, env=self.env, text=True, capture_output=True)
        if check and result.returncode:
            raise AssertionError(f"{args}:\n{result.stdout}{result.stderr}")
        return result

    def git(self, path, *args):
        return self.run(["git", "-c", "core.hooksPath=/dev/null", *args], path).stdout.strip()

    def commit_glyphs(self, version):
        (self.source / "version").write_text(version)
        self.git(self.source, "add", "version")
        self.git(self.source, "commit", "--quiet", "-m", version)
        return self.git(self.source, "rev-parse", "HEAD")

    def clone_glyphs(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        self.git(self.root, "clone", "--quiet", str(self.source), str(path))
        self.git(path, "checkout", "--quiet", "--detach", self.old)

    def pin(self, parent, sha):
        # Model the consumer's recorded dependency separately from its checkout.
        self.git(parent / "charts", "checkout", "--quiet", "--detach", sha)
        self.git(parent, "update-index", "--add", "--cacheinfo", f"160000,{sha},charts")
        if parent.name == "covenant" and not (parent / "bookrack").is_symlink():
            (parent / "bookrack").symlink_to("../bookrack")
            self.git(parent, "add", "bookrack")
        self.git(parent, "commit", "--quiet", "--allow-empty", "-m", "Pin Glyphs")

    def select_candidate(self, sha, component="kaster"):
        self.component = component
        self.pin(self.checkout / CONSUMERS[component], sha)

    def make(self, target, check=True):
        return self.run([
            "make", "--no-print-directory", "-f", str(MAKEFILE), target,
            f"COMPONENT={self.component}",
            "LIBRARIAN_BOOKS_FILE=/dev/null",
            "COVENANT_APPLICATION_BOOKS_FILE=/dev/null",
            "COVENANT_IAM_BOOKS_FILE=/dev/null",
        ], self.checkout, check=check)

    def heads(self):
        return [self.git(path, "rev-parse", "HEAD") for path in self.glyph_paths()]

    def glyph_paths(self):
        return [self.canonical, *(self.checkout / path / "charts" for path in CONSUMERS.values())]

    def assert_rejected_without_checkout_changes(self, test, message):
        before = self.heads()
        result = self.make("prepare-component-candidate", check=False)
        test.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        test.assertIn(message, result.stdout + result.stderr)
        test.assertEqual(self.heads(), before)


class ComponentCandidateTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="runik-candidate-")
        self.addCleanup(self.directory.cleanup)
        self.fixture = CandidateFixture(self.directory.name)

    def test_all_consumers_prepare_exact_merged_dependency_without_changing_gitlinks(self):
        f = self.fixture
        for component in CONSUMERS:
            with self.subTest(component=component):
                for path in f.glyph_paths():
                    f.git(path, "checkout", "--quiet", "--detach", f.old)
                f.select_candidate(f.candidate, component)
                before = {
                    path: f.git(f.checkout / path, "ls-files", "--stage", "charts")
                    for path in CONSUMERS.values()
                }
                self.assertNotEqual(f.make("verify-component-candidate", check=False).returncode, 0)
                f.make("prepare-component-candidate")
                self.assertEqual(f.heads(), [f.candidate] * 6)
                f.make("verify-component-candidate")
                f.make("prepare-component-candidate")  # Idempotent after preparation.
                for path, recorded in before.items():
                    self.assertEqual(f.git(f.checkout / path, "ls-files", "--stage", "charts"), recorded)

    def test_unchanged_dependency_preserves_current_set(self):
        f = self.fixture
        f.make("prepare-component-candidate")
        self.assertEqual(f.heads(), [f.old] * 6)
        f.make("verify-component-candidate")

    def test_rejects_unmerged_dependency(self):
        f = self.fixture
        f.select_candidate(f.unmerged)
        f.assert_rejected_without_checkout_changes(self, "must already be merged")

    def test_rejects_dependency_rollback(self):
        f = self.fixture
        for path in f.glyph_paths():
            f.git(path, "checkout", "--quiet", "--detach", f.latest)
        f.select_candidate(f.candidate)
        f.assert_rejected_without_checkout_changes(self, "must advance")

    def test_rejects_unrelated_mirror_desynchronization(self):
        f = self.fixture
        f.select_candidate(f.candidate)
        f.git(f.checkout / "charts/summon/charts", "checkout", "--quiet", "--detach", f.latest)
        f.assert_rejected_without_checkout_changes(self, "Unrelated Glyphs mismatch")

    def test_unchanged_candidate_does_not_hide_other_mirror_mismatch(self):
        f = self.fixture
        f.git(f.checkout / "charts/summon/charts", "checkout", "--quiet", "--detach", f.latest)
        f.make("prepare-component-candidate")
        self.assertNotEqual(f.make("verify-component-candidate", check=False).returncode, 0)

    def test_rejects_checkout_that_differs_from_committed_candidate_pin(self):
        f = self.fixture
        f.select_candidate(f.candidate)
        f.git(f.checkout / "charts/kaster/charts", "checkout", "--quiet", "--detach", f.latest)
        f.assert_rejected_without_checkout_changes(self, "does not match its committed dependency")

    def test_rejects_dirty_glyph_checkout_before_moving_any_heads(self):
        f = self.fixture
        f.select_candidate(f.candidate)
        (f.checkout / "covenant/charts/version").write_text("local edit")
        f.assert_rejected_without_checkout_changes(self, "Dirty Glyphs checkout")

    def test_glyph_candidate_still_requires_all_mirrors(self):
        f = self.fixture
        f.component = "glyphs"
        f.git(f.canonical, "checkout", "--quiet", "--detach", f.candidate)
        f.make("prepare-component-candidate")
        self.assertNotEqual(f.make("verify-component-candidate", check=False).returncode, 0)

    def test_rejects_unknown_component(self):
        f = self.fixture
        f.component = "unknown"
        f.assert_rejected_without_checkout_changes(self, "Unsupported Runik component")


if __name__ == "__main__":
    unittest.main(verbosity=2)
