locals {
  sri_sg_rule_source = {
    Owner            = "CUSTOM_LAMBDA"
    SourceIdentifier = aws_lambda_function.sri_sg_rule_lambda.arn
    SourceDetails = [{
      EventSource = "aws.config"
      MessageType = "ConfigurationItemChangeNotification"
    }]
  }

  sri_sg_scope = {
    ComplianceResourceTypes = ["AWS::EC2::SecurityGroup"]
  }
}

resource "aws_config_conformance_pack" "sri_conformance_pack" {
  name = "sri-conformance-pack"

  template_body = yamlencode({
    Resources = {
      SriDetectiveRule = {
        Type = "AWS::Config::ConfigRule"
        Properties = {
          ConfigRuleName = "sri-detective-rule"
          Scope          = local.sri_sg_scope
          Source         = local.sri_sg_rule_source
        }
      }

      SriReactiveRule = {
        Type = "AWS::Config::ConfigRule"
        Properties = {
          ConfigRuleName  = "sri-reactive-rule"
          InputParameters = { restrictedPorts = "22,3389,9092,9093" }
          Scope           = local.sri_sg_scope
          Source          = local.sri_sg_rule_source
        }
      }

      SriRemediation = {
        Type      = "AWS::Config::RemediationConfiguration"
        DependsOn = "SriReactiveRule"
        Properties = {
          ConfigRuleName           = "sri-reactive-rule"
          TargetType               = "SSM_DOCUMENT"
          TargetId                 = "AWSConfigRemediation-RemoveUnrestrictedSourceIngressRules"
          Automatic                = true
          MaximumAutomaticAttempts = 3
          RetryAttemptSeconds      = 60
          Parameters = {
            SecurityGroupId      = { ResourceValue = { Value = "RESOURCE_ID" } }
            AutomationAssumeRole = { StaticValue = { Values = [aws_iam_role.sri_remediation_role.arn] } }
          }
        }
      }
    }
  })

  depends_on = [
    aws_lambda_permission.sri_config_invoke,
    aws_iam_role_policy.sri_remediation_policy,
    aws_config_configuration_recorder_status.sri_config_recorder_status,
  ]
}
