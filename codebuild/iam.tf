resource "aws_iam_role" "sri_codebuild_role" {
  name = "sri-codebuild-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sri_codebuild_admin" {
  role       = aws_iam_role.sri_codebuild_role.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
