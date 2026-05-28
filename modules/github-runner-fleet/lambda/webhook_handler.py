"""
GitHub webhook handler for GitHub Actions runner fleet scaling.

Receives workflow_job events from GitHub via API Gateway HTTP API.
Verifies HMAC-SHA256 signature, then adjusts ECS service desired_count.

Environment variables (set by Terraform):
  ECS_CLUSTER        - ECS cluster name
  ECS_SERVICE        - ECS service name
  MAX_RUNNERS        - Maximum allowed desired_count
  MIN_RUNNERS        - Minimum desired_count
  WEBHOOK_SECRET_ARN - Secrets Manager ARN for the webhook HMAC secret
"""

import hashlib
import hmac
import json
import logging
import os

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ecs = boto3.client("ecs")
sm = boto3.client("secretsmanager")
_wh_secret = None  # module-level cache across warm invocations


def _get_webhook_secret() -> str:
    """Retrieve and cache the webhook HMAC secret from Secrets Manager."""
    global _wh_secret
    if _wh_secret is None:
        resp = sm.get_secret_value(SecretId=os.environ["WEBHOOK_SECRET_ARN"])
        _wh_secret = resp.get("SecretString") or ""
    return _wh_secret


def _verify_signature(body: bytes, sig_header: str) -> bool:
    """Verify the GitHub HMAC-SHA256 webhook signature.

    GitHub sends the signature in the header 'X-Hub-Signature-256'
    in the format 'sha256=<hex_digest>'.

    Returns True only when the computed digest matches the provided header
    using a constant-time comparison to prevent timing attacks.
    """
    if not sig_header or not sig_header.startswith("sha256="):
        return False
    secret = _get_webhook_secret().encode("utf-8")
    expected = "sha256=" + hmac.new(secret, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, sig_header)


def _get_current_desired(cluster: str, service: str) -> int:
    """Return the current desiredCount for the ECS service."""
    resp = ecs.describe_services(cluster=cluster, services=[service])
    services = resp.get("services", [])
    if not services:
        raise ValueError(f"ECS service '{service}' not found in cluster '{cluster}'")
    return services[0]["desiredCount"]


def _set_desired(cluster: str, service: str, count: int) -> None:
    """Update the desiredCount on the ECS service and log the result."""
    ecs.update_service(cluster=cluster, service=service, desiredCount=count)
    logger.info(
        json.dumps(
            {
                "event": "ecs_scaled",
                "cluster": cluster,
                "service": service,
                "desired_count": count,
            }
        )
    )


def handler(event, context):
    """
    Lambda entry point for GitHub workflow_job webhooks via API Gateway HTTP API.

    Supported actions:
      queued      -> increment ECS service desired_count by 1 (up to max_runners)
      in_progress -> no-op (runner picked up the job)
      completed   -> no-op (ephemeral runner already exited, ECS task stopped)
      waiting     -> no-op

    Returns API Gateway v2 response format.
    """
    cluster = os.environ["ECS_CLUSTER"]
    service = os.environ["ECS_SERVICE"]
    max_r = int(os.environ.get("MAX_RUNNERS", "20"))

    # API Gateway HTTP API v2 sends lowercase header names
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    raw_body = event.get("body", "") or ""
    body_bytes = raw_body.encode("utf-8") if isinstance(raw_body, str) else raw_body

    # ------------------------------------------------------------------
    # Step 1: Verify HMAC signature
    # ------------------------------------------------------------------
    sig_header = headers.get("x-hub-signature-256", "")
    if not _verify_signature(body_bytes, sig_header):
        logger.warning(
            json.dumps(
                {
                    "event": "signature_rejected",
                    "sig_present": bool(sig_header),
                    "source_ip": (event.get("requestContext") or {})
                    .get("http", {})
                    .get("sourceIp"),
                }
            )
        )
        return {
            "statusCode": 401,
            "body": json.dumps({"error": "Unauthorized: invalid or missing signature"}),
        }

    # ------------------------------------------------------------------
    # Step 2: Parse payload
    # ------------------------------------------------------------------
    try:
        payload = json.loads(raw_body)
    except json.JSONDecodeError as exc:
        logger.error(json.dumps({"event": "parse_error", "detail": str(exc)}))
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Bad Request: payload is not valid JSON"}),
        }

    github_event = headers.get("x-github-event", "")
    action = payload.get("action", "")
    job = payload.get("workflow_job", {})

    logger.info(
        json.dumps(
            {
                "event": "webhook_received",
                "github_event": github_event,
                "action": action,
                "job_id": job.get("id"),
                "job_name": job.get("name"),
                "repo": (payload.get("repository") or {}).get("full_name"),
                "labels": job.get("labels", []),
            }
        )
    )

    # Only react to workflow_job events
    if github_event != "workflow_job":
        return {
            "statusCode": 200,
            "body": json.dumps({"message": f"ignored: event={github_event}"}),
        }

    # ------------------------------------------------------------------
    # Step 3: Scale-up on queued jobs
    # ------------------------------------------------------------------
    if action == "queued":
        try:
            current = _get_current_desired(cluster, service)
            if current < max_r:
                new_count = min(current + 1, max_r)
                _set_desired(cluster, service, new_count)
                return {
                    "statusCode": 200,
                    "body": json.dumps(
                        {"message": "scaled_up", "desired_count": new_count}
                    ),
                }
            else:
                logger.info(
                    json.dumps(
                        {
                            "event": "max_runners_reached",
                            "max_runners": max_r,
                            "current": current,
                        }
                    )
                )
                return {
                    "statusCode": 200,
                    "body": json.dumps(
                        {"message": "max_runners_reached", "desired_count": current}
                    ),
                }
        except Exception as exc:  # noqa: BLE001
            logger.error(
                json.dumps({"event": "scale_error", "detail": str(exc)})
            )
            return {
                "statusCode": 500,
                "body": json.dumps({"error": "Internal error during scale-up"}),
            }

    # All other actions are no-ops (in_progress, completed, waiting)
    return {
        "statusCode": 200,
        "body": json.dumps({"message": f"no-op: action={action}"}),
    }
