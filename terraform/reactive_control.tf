resource "aws_config_config_rule" "sri_reactive_rule" {
  name             = "sri-reactive-rule"
  input_parameters = jsonencode({ restrictedPorts = "22,3389,9092,9093" })

  scope {
    compliance_resource_types = ["AWS::EC2::SecurityGroup"]
  }

  source {
    owner             = "CUSTOM_LAMBDA"
    source_identifier = aws_lambda_function.sri_sg_rule_lambda.arn

    source_detail {
      message_type = "ConfigurationItemChangeNotification"
    }
  }

  depends_on = [aws_lambda_permission.sri_config_invoke, aws_config_configuration_recorder_status.sri_config_recorder_status]
}

resource "aws_iam_role" "sri_remediation_role" {
  name = "sri-remediation-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ssm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sri_remediation_policy" {
  name = "sri-remediation-policy"
  role = aws_iam_role.sri_remediation_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeSecurityGroups", "ec2:RevokeSecurityGroupIngress", "ec2:GetManagedPrefixListEntries"]
      Resource = "*"
    }]
  })
}

resource "aws_config_remediation_configuration" "sri_remediation" {
  config_rule_name = aws_config_config_rule.sri_reactive_rule.name
  target_type      = "SSM_DOCUMENT"
  target_id        = "AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules"
  automatic        = true

  parameter {
    name           = "SecurityGroupId"
    resource_value = "RESOURCE_ID"
  }

  parameter {
    name         = "AutomationAssumeRole"
    static_value = aws_iam_role.sri_remediation_role.arn
  }
}
