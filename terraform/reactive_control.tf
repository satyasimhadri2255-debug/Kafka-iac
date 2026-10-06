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
