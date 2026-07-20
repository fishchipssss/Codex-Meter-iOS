import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "codex_meter_proxy.py"
SPEC = importlib.util.spec_from_file_location("codex_meter_proxy", MODULE_PATH)
proxy = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(proxy)


class NormalizationTests(unittest.TestCase):
    def test_normalizes_rate_limit(self):
        value = proxy.normalize_rate_limit({
            "limitId": "codex",
            "primary": {"usedPercent": 22, "windowDurationMins": 300, "resetsAt": 123},
            "secondary": {"usedPercent": 65, "windowDurationMins": 10080, "resetsAt": 456},
        })
        self.assertEqual(value["limit_id"], "codex")
        self.assertEqual(value["primary"]["window_duration_minutes"], 300)
        self.assertEqual(value["secondary"]["used_percent"], 65)

    def test_clamps_used_percent(self):
        self.assertEqual(proxy.normalize_window({"usedPercent": 200})["used_percent"], 100)

    def test_normalizes_reset_credits(self):
        value = proxy.normalize_reset_credits({
            "availableCount": 2,
            "credits": [{"id": "one", "status": "available", "resetType": "codexRateLimits"}],
        })
        self.assertEqual(value["available_count"], 2)
        self.assertEqual(value["credits"][0]["reset_type"], "codexRateLimits")


class PairingTests(unittest.TestCase):
    def test_pairing_code_contains_version_and_https_url(self):
        code = proxy.pairing_code({
            "proxy_id": "e675d48e-38c3-433f-aa40-c41a7699d544",
            "name": "Mini",
            "public_url": "https://mini.example.ts.net:8443/",
            "token": "secret",
        })
        self.assertTrue(code.startswith("codexmeter://proxy/add?"))
        self.assertIn("v=1", code)
        self.assertIn("https%3A%2F%2Fmini.example.ts.net%3A8443", code)


if __name__ == "__main__":
    unittest.main()
