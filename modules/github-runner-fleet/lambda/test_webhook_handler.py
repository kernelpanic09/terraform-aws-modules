"""Unit tests for pure-logic functions in the github-runner-fleet Lambda handler.

These tests cover functions that have no AWS dependencies and can run
without credentials or network access.
"""
import hashlib
import hmac
import json
import os
import sys
from unittest.mock import MagicMock, patch

# Satisfy module-level os.environ reads before importing handler
os.environ.update(
    {
        "ECS_CLUSTER": "test-cluster",
        "ECS_SERVICE": "test-service",
        "MAX_RUNNERS": "10",
        "MIN_RUNNERS": "0",
        "WEBHOOK_SECRET_ARN": "arn:aws:secretsmanager:us-east-1:123456789012:secret/test",
    }
)

# Stub boto3 so module-level client creation doesn't contact AWS
with patch("boto3.client", return_value=MagicMock()):
    sys.path.insert(0, os.path.dirname(__file__))
    import webhook_handler as wh  # noqa: E402

import pytest

_SECRET = "test-webhook-secret"


def _make_sig(body: bytes, secret: str = _SECRET) -> str:
    digest = hmac.new(secret.encode(), body, hashlib.sha256).hexdigest()
    return f"sha256={digest}"


# ---------------------------------------------------------------------------
# _verify_signature
# ---------------------------------------------------------------------------
class TestVerifySignature:
    def test_valid_signature_returns_true(self):
        body = b'{"action":"queued"}'
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            assert wh._verify_signature(body, _make_sig(body)) is True

    def test_wrong_secret_returns_false(self):
        body = b'{"action":"queued"}'
        with patch.object(wh, "_get_webhook_secret", return_value="wrong-secret"):
            assert wh._verify_signature(body, _make_sig(body)) is False

    def test_tampered_body_returns_false(self):
        body = b'{"action":"queued"}'
        sig = _make_sig(body)
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            assert wh._verify_signature(b'{"action":"completed"}', sig) is False

    def test_missing_sig_header_returns_false(self):
        assert wh._verify_signature(b"body", "") is False

    def test_none_sig_header_returns_false(self):
        assert wh._verify_signature(b"body", None) is False

    def test_wrong_prefix_returns_false(self):
        # Must start with "sha256=" - anything else is rejected before HMAC check
        assert wh._verify_signature(b"body", "md5=abc123") is False

    def test_sha256_prefix_without_digest_returns_false(self):
        body = b"hello"
        # "sha256=" prefix but wrong digest value
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            assert wh._verify_signature(body, "sha256=badhex") is False

    def test_empty_body_valid_sig(self):
        body = b""
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            assert wh._verify_signature(body, _make_sig(body)) is True


# ---------------------------------------------------------------------------
# handler - signature enforcement
# ---------------------------------------------------------------------------
class TestHandlerSignatureEnforcement:
    def _event(self, body: dict, extra_headers: dict = None) -> dict:
        raw = json.dumps(body)
        headers = {"x-github-event": "workflow_job", "x-hub-signature-256": "sha256=bad"}
        if extra_headers:
            headers.update(extra_headers)
        return {"headers": headers, "body": raw}

    def test_bad_signature_returns_401(self):
        event = self._event({"action": "queued", "workflow_job": {}})
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 401

    def test_missing_signature_returns_401(self):
        event = self._event({"action": "queued", "workflow_job": {}})
        event["headers"].pop("x-hub-signature-256")
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 401


# ---------------------------------------------------------------------------
# handler - event and action routing
# ---------------------------------------------------------------------------
class TestHandlerRouting:
    def _signed_event(self, body: dict, github_event: str = "workflow_job") -> dict:
        raw = json.dumps(body)
        sig = _make_sig(raw.encode())
        return {
            "headers": {
                "x-github-event": github_event,
                "x-hub-signature-256": sig,
            },
            "body": raw,
        }

    def test_non_workflow_job_event_returns_200_ignored(self):
        event = self._signed_event({"action": "opened"}, github_event="pull_request")
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        assert "ignored" in json.loads(resp["body"])["message"]

    def test_in_progress_action_is_noop(self):
        event = self._signed_event({"action": "in_progress", "workflow_job": {}})
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        assert "no-op" in json.loads(resp["body"])["message"]

    def test_completed_action_is_noop(self):
        event = self._signed_event({"action": "completed", "workflow_job": {}})
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        assert "no-op" in json.loads(resp["body"])["message"]

    def test_waiting_action_is_noop(self):
        event = self._signed_event({"action": "waiting", "workflow_job": {}})
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        assert "no-op" in json.loads(resp["body"])["message"]

    def test_queued_below_max_scales_up(self):
        event = self._signed_event({"action": "queued", "workflow_job": {}})
        with (
            patch.object(wh, "_get_webhook_secret", return_value=_SECRET),
            patch.object(wh, "_get_current_desired", return_value=3),
            patch.object(wh, "_set_desired") as mock_set,
        ):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        body = json.loads(resp["body"])
        assert body["message"] == "scaled_up"
        assert body["desired_count"] == 4
        mock_set.assert_called_once_with(
            os.environ["ECS_CLUSTER"], os.environ["ECS_SERVICE"], 4
        )

    def test_queued_at_max_does_not_scale(self):
        event = self._signed_event({"action": "queued", "workflow_job": {}})
        max_r = int(os.environ["MAX_RUNNERS"])
        with (
            patch.object(wh, "_get_webhook_secret", return_value=_SECRET),
            patch.object(wh, "_get_current_desired", return_value=max_r),
            patch.object(wh, "_set_desired") as mock_set,
        ):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 200
        assert "max_runners_reached" in json.loads(resp["body"])["message"]
        mock_set.assert_not_called()

    def test_invalid_json_body_returns_400(self):
        raw = "not-json"
        sig = _make_sig(raw.encode())
        event = {
            "headers": {
                "x-github-event": "workflow_job",
                "x-hub-signature-256": sig,
            },
            "body": raw,
        }
        with patch.object(wh, "_get_webhook_secret", return_value=_SECRET):
            resp = wh.handler(event, None)
        assert resp["statusCode"] == 400
