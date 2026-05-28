###############################################################################
# Outputs
###############################################################################

output "guardrail_id" {
  description = "Unique ID of the Bedrock guardrail (used in API calls as guardrailIdentifier)."
  value       = aws_bedrock_guardrail.this.guardrail_id
}

output "guardrail_arn" {
  description = "ARN of the Bedrock guardrail."
  value       = aws_bedrock_guardrail.this.guardrail_arn
}

output "guardrail_version" {
  description = <<-EOT
    Immutable version number published by aws_bedrock_guardrail_version.
    Null when enable_versioning is false.
    Use this value as guardrailVersion in SDK/API calls to pin production
    traffic to a known-good snapshot.
  EOT
  value       = var.enable_versioning ? aws_bedrock_guardrail_version.this[0].version : null
}

output "guardrail_version_arn" {
  description = <<-EOT
    Full ARN including the version number, suitable for use as a resource ARN in
    IAM policies and SDK configuration. Null when enable_versioning is false.
  EOT
  value = (
    var.enable_versioning
    ? "${aws_bedrock_guardrail.this.guardrail_arn}:${aws_bedrock_guardrail_version.this[0].version}"
    : null
  )
}

output "invoke_policy_json" {
  description = <<-EOT
    Rendered IAM policy document JSON that grants the principal_arns permission to
    invoke Bedrock foundation models and apply this guardrail. Attach this to an
    aws_iam_policy or aws_iam_role_policy in the calling module.

    Null when principal_arns is empty.
  EOT
  value = (
    length(var.principal_arns) > 0
    ? data.aws_iam_policy_document.invoke_with_guardrail[0].json
    : null
  )
}

output "invoke_policy_json_encoded" {
  description = <<-EOT
    URL-encoded form of invoke_policy_json, ready for use as an inline session
    policy or in contexts that require URI-encoded JSON. Null when principal_arns
    is empty.
  EOT
  value = (
    length(var.principal_arns) > 0
    ? urlencode(data.aws_iam_policy_document.invoke_with_guardrail[0].json)
    : null
  )
}

output "name" {
  description = "Name of the guardrail, as provided."
  value       = aws_bedrock_guardrail.this.name
}
