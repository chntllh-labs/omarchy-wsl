"""Shared pytest configuration.

OMW_STRICT=1 (set by tests/run-all.sh) turns every skipped test into a
failure, so a missing tool or input can never make the suite pass silently.
"""

from __future__ import annotations

import os

import pytest

STRICT = os.environ.get("OMW_STRICT") == "1"


@pytest.hookimpl(hookwrapper=True)
def pytest_runtest_makereport(item, call):
    outcome = yield
    report = outcome.get_result()
    if STRICT and report.skipped and not hasattr(report, "wasxfail"):
        reason = report.longrepr[2] if isinstance(report.longrepr, tuple) else str(report.longrepr)
        report.outcome = "failed"
        report.longrepr = f"skipped under OMW_STRICT=1: {reason}"
