"""Tests for the flat metrics schema and flattening."""

import unittest

from chopshop_plot import metrics
from chopshop_plot.metrics import flatten_run, recipe_hash, METRICS_VERSION

from fixtures import make_candidate, make_run


class TestRecipeHash(unittest.TestCase):
    def test_deterministic(self):
        self.assertEqual(recipe_hash("flat-poster", 2, False, False),
                         recipe_hash("flat-poster", 2, False, False))

    def test_order_independent_of_types(self):
        # bool/int equivalence: True == 1 in JSON, so a recipe expressed with
        # True and 1 must hash the same.
        self.assertEqual(recipe_hash("x", 1, True, False),
                         recipe_hash("x", 1, True, False))

    def test_different_recipes_differ(self):
        self.assertNotEqual(recipe_hash("a", 2, False, False),
                            recipe_hash("b", 2, False, False))
        self.assertNotEqual(recipe_hash("a", 2, False, False),
                            recipe_hash("a", 4, False, False))


class TestFlatten(unittest.TestCase):
    def setUp(self):
        src = "s" * 64
        self.candidate = make_candidate(
            "c1", preset="flat-poster", speckle=2, hier=False, palette=False,
            hard=0, advisory=1, passed=True, declared=5, inks=5,
            nodes_total=1234, nodes_max=87, size=45678,
            mae=0.12, mae_art=0.005, p95=2.0, within10=0.98,
            verdict="faithful", selected=True, label="production",
            manifest={"passed": True, "stats": {
                "tac_exact": True, "rendered_continuous_tone": False,
                "rendered_distinct_colors": 5, "hard_findings": 0,
                "advisory_findings": 1, "color_count": 5,
                "static": {"path_nodes_max": 87}}},
        )
        self.run = make_run("stem-1", src, [self.candidate])
        self.rows, self.meta = flatten_run(self.run)

    def test_one_row_per_candidate(self):
        self.assertEqual(len(self.rows), 1)
        self.assertEqual(self.meta["candidate_count"], 1)
        self.assertEqual(self.meta["stem"], "stem-1")

    def test_identity_fields(self):
        row = self.rows[0]
        self.assertEqual(row["candidate_id"], "c1")
        self.assertEqual(row["run_stem"], "stem-1")
        self.assertEqual(row["source_sha256"], "s" * 64)
        self.assertEqual(row["recipe_hash"],
                         recipe_hash("flat-poster", 2, False, False))

    def test_numeric_fields_flatten_flat(self):
        row = self.rows[0]
        self.assertEqual(row["node_count_max"], 87)
        self.assertEqual(row["node_count_total"], 1234)
        self.assertEqual(row["declared_colors"], 5)
        self.assertEqual(row["rendered_ink_colors"], 5)
        self.assertEqual(row["mae_art"], 0.005)
        self.assertEqual(row["file_size"], 45678)

    def test_manifest_fields_flatten(self):
        row = self.rows[0]
        self.assertEqual(row["tac_exact"], True)
        self.assertEqual(row["rendered_distinct_colors"], 5)
        self.assertEqual(row["hard_findings"], 0)
        self.assertEqual(row["advisory_findings"], 1)

    def test_categorical_fields(self):
        row = self.rows[0]
        self.assertEqual(row["preset"], "flat-poster")
        self.assertEqual(row["passed"], True)
        self.assertEqual(row["fidelity_verdict"], "faithful")
        self.assertEqual(row["label"], "production")
        self.assertEqual(row["selected"], True)

    def test_missing_data_is_none_not_zero(self):
        # A candidate with no comparison and no manifest: gates and metrics
        # must be None (absent), never 0.
        bare = make_candidate("bare", preset="x", speckle=0, hier=False,
                              palette=False)
        bare["comparison"] = None
        bare["back_half"] = {"run": False, "manifest": None}
        row = flatten_run(make_run("s", "u" * 64, [bare]))[0][0]
        self.assertIsNone(row["hard"])
        self.assertIsNone(row["mae_art"])
        self.assertIsNone(row["node_count_max"])
        self.assertIsNone(row["declared_colors"])
        # but identity + recipe still present
        self.assertEqual(row["candidate_id"], "bare")
        self.assertIsNotNone(row["recipe_hash"])

    def test_field_registry_consistent(self):
        # Every ALL_FIELDS entry must be queryable via the known_field helper.
        for field in metrics.ALL_FIELDS:
            self.assertTrue(metrics.known_field(field), field)
        self.assertTrue(metrics.is_numeric_field("mae_art"))
        self.assertFalse(metrics.is_numeric_field("preset"))
        self.assertTrue(metrics.is_categorical_field("preset"))

    def test_schema_version_pinned(self):
        self.assertEqual(METRICS_VERSION, 1)


if __name__ == "__main__":
    unittest.main()
