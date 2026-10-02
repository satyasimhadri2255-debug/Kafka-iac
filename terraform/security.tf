# Security controls: a custom Config rule (detective), an auto-remediating Config rule
# (reactive), both bundled into one conformance pack. These are account/region-wide:
# they evaluate every security group in us-east-2, not only the Kafka one.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  restricted_ports = join(",", var.restricted_ports)
}

# ---------------------------------------------------------------------------
# AWS Config recorder. Conformance packs need one. An account allows one recorder
# per region, so set create_config_recorder = false if Config is already on
# (for example in a Control Tower-managed account).
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "config" {
  count         = var.create_config_recorder ? 1 : 0
  bucket_prefix = "${var.name}-config-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "config" {
  count                   = var.create_config_recorder ? 1 : 0
  bucket                  = aws_s3_bucket.config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_policy" "config" {
  count  = var.create_config_recorder ? 1 : 0
  bucket = aws_s3_bucket.config[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ConfigBucketCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = aws_s3_bucket.config[0].arn
        Condition = { StringEquals = { "AWS:SourceAccount" = data.aws_caller_identity.current.account_id } }
      },
      {
        Sid       = "ConfigBucketDelivery"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.config[0].arn, "${aws_s3_bucket.config[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
}

resource "aws_iam_role" "config" {
  count = var.create_config_recorder ? 1 : 0
  name  = "${var.name}-config-recorder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "config.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "config" {
  count      = var.create_config_recorder ? 1 : 0
  role       = aws_iam_role.config[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_config_configuration_recorder" "this" {
  count    = var.create_config_recorder ? 1 : 0
  name     = "${var.name}-recorder"
  role_arn = aws_iam_role.config[0].arn

  # Record only what the rules need, to keep Config costs down.
  recording_group {
    all_supported  = false
    resource_types = ["AWS::EC2::SecurityGroup"]
  }
}

resource "aws_config_delivery_channel" "this" {
  count          = var.create_config_recorder ? 1 : 0
  name           = "${var.name}-delivery"
  s3_bucket_name = aws_s3_bucket.config[0].bucket

  depends_on = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  count      = var.create_config_recorder ? 1 : 0
  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.this]
}

# ---------------------------------------------------------------------------
# Detective control: Lambda that evaluates security groups for world-open ingress.
# Both Config rules use it; the reactive rule passes `restrictedPorts`.
# ---------------------------------------------------------------------------

data "archive_file" "sg_rule" {
  type        = "zip"
  source_file = "${path.module}/lambda/sg_world_ingress.py"
  output_path = "${path.module}/.build/sg_world_ingress.zip"
}

resource "aws_iam_role" "sg_rule" {
  name = "${var.name}-sg-rule-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sg_rule_logs" {
  role       = aws_iam_role.sg_rule.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# PutEvaluations, plus read access for oversized configuration items.
resource "aws_iam_role_policy_attachment" "sg_rule_config" {
  role       = aws_iam_role.sg_rule.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSConfigRulesExecutionRole"
}

resource "aws_lambda_function" "sg_rule" {
  function_name    = "${var.name}-sg-world-ingress"
  description      = "Custom AWS Config rule: security groups open to 0.0.0.0/0 or ::/0"
  role             = aws_iam_role.sg_rule.arn
  runtime          = "python3.13"
  handler          = "sg_world_ingress.handler"
  filename         = data.archive_file.sg_rule.output_path
  source_code_hash = data.archive_file.sg_rule.output_base64sha256
  timeout          = 30
}

resource "aws_lambda_permission" "config" {
  statement_id   = "AllowConfigInvoke"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.sg_rule.function_name
  principal      = "config.amazonaws.com"
  source_account = data.aws_caller_identity.current.account_id
}

# ---------------------------------------------------------------------------
# Reactive control: SSM Automation document that revokes the offending rules.
# ---------------------------------------------------------------------------

resource "aws_ssm_document" "revoke_world_ingress" {
  name            = "${var.name}-RevokeWorldIngress"
  document_type   = "Automation"
  document_format = "YAML"
  content         = <<-YAML
    schemaVersion: "0.3"
    description: >-
      Revokes security group ingress rules that are open to 0.0.0.0/0 or ::/0 and cover
      one of the restricted ports. Used as the auto-remediation for the Config rule.
    assumeRole: "{{ AutomationAssumeRole }}"
    parameters:
      GroupId:
        type: String
        description: Security group to fix.
      RestrictedPorts:
        type: String
        description: Comma-separated ports that must not be open to the internet.
      AutomationAssumeRole:
        type: String
        description: Role that Automation assumes to change the security group.
    mainSteps:
      - name: RevokeWorldIngress
        action: aws:executeScript
        inputs:
          Runtime: python3.11
          Handler: handler
          InputPayload:
            GroupId: "{{ GroupId }}"
            RestrictedPorts: "{{ RestrictedPorts }}"
          Script: |-
            import boto3

            WORLD = {"0.0.0.0/0", "::/0"}

            def handler(event, _context):
                ec2 = boto3.client("ec2")
                ports = [int(p) for p in event["RestrictedPorts"].split(",") if p.strip()]
                rules = ec2.describe_security_group_rules(
                    Filters=[{"Name": "group-id", "Values": [event["GroupId"]]}]
                )["SecurityGroupRules"]
                revoke = []
                for r in rules:
                    if r["IsEgress"] or not {r.get("CidrIpv4"), r.get("CidrIpv6")} & WORLD:
                        continue
                    if r["IpProtocol"] == "-1":
                        lo, hi = 0, 65535
                    elif r["IpProtocol"] in ("tcp", "udp", "6", "17"):
                        lo, hi = r["FromPort"], r["ToPort"]
                    else:
                        continue
                    if any(lo <= p <= hi for p in ports):
                        revoke.append(r["SecurityGroupRuleId"])
                if revoke:
                    ec2.revoke_security_group_ingress(GroupId=event["GroupId"], SecurityGroupRuleIds=revoke)
                return {"revoked": revoke}
        outputs:
          - Name: RevokedRuleIds
            Selector: $.Payload.revoked
            Type: StringList
        isEnd: true
  YAML
}

resource "aws_iam_role" "remediation" {
  name = "${var.name}-sg-remediation"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "remediation" {
  name = "revoke-world-ingress"
  role = aws_iam_role.remediation.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ec2:DescribeSecurityGroupRules"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "ec2:RevokeSecurityGroupIngress"
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*:${data.aws_caller_identity.current.account_id}:security-group/*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Conformance pack: both rules plus the remediation, deployed as one unit.
# ---------------------------------------------------------------------------

resource "aws_config_conformance_pack" "sg_controls" {
  name = "${var.name}-sg-controls"
  # Keep these values in the template rather than using input_parameter blocks;
  # passing three or more parameters can make AWS Config reject the Lambda rule
  # because it considers the function to be in a different region.
  template_body = <<-YAML
    Resources:
      # Detective control: reports every security group with any ingress open to the internet.
      SgNoWorldIngress:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: sg-no-world-ingress
          Description: Flags security groups with any ingress rule open to 0.0.0.0/0 or ::/0.
          Scope:
            ComplianceResourceTypes:
              - AWS::EC2::SecurityGroup
          Source:
            Owner: CUSTOM_LAMBDA
            SourceIdentifier: ${aws_lambda_function.sg_rule.arn}
            SourceDetails:
              - EventSource: aws.config
                MessageType: ConfigurationItemChangeNotification
              - EventSource: aws.config
                MessageType: OversizedConfigurationItemChangeNotification

      # Reactive control: sensitive ports open to the internet are revoked automatically.
      SgNoWorldIngressRestrictedPorts:
        Type: AWS::Config::ConfigRule
        Properties:
          ConfigRuleName: sg-no-world-ingress-restricted-ports
          Description: Flags and auto-remediates security groups that open restricted ports to 0.0.0.0/0 or ::/0.
          InputParameters:
            restrictedPorts: "${local.restricted_ports}"
          Scope:
            ComplianceResourceTypes:
              - AWS::EC2::SecurityGroup
          Source:
            Owner: CUSTOM_LAMBDA
            SourceIdentifier: ${aws_lambda_function.sg_rule.arn}
            SourceDetails:
              - EventSource: aws.config
                MessageType: ConfigurationItemChangeNotification
              - EventSource: aws.config
                MessageType: OversizedConfigurationItemChangeNotification

      SgNoWorldIngressRestrictedPortsRemediation:
        Type: AWS::Config::RemediationConfiguration
        DependsOn: SgNoWorldIngressRestrictedPorts
        Properties:
          ConfigRuleName: sg-no-world-ingress-restricted-ports
          TargetType: SSM_DOCUMENT
          TargetId: ${aws_ssm_document.revoke_world_ingress.name}
          Automatic: ${var.automatic_remediation}
          MaximumAutomaticAttempts: 3
          RetryAttemptSeconds: 60
          Parameters:
            GroupId:
              ResourceValue:
                Value: RESOURCE_ID
            RestrictedPorts:
              StaticValue:
                Values:
                  - "${local.restricted_ports}"
            AutomationAssumeRole:
              StaticValue:
                Values:
                  - ${aws_iam_role.remediation.arn}
  YAML

  depends_on = [
    aws_lambda_permission.config,
    aws_iam_role_policy.remediation,
    aws_config_configuration_recorder_status.this,
  ]
}