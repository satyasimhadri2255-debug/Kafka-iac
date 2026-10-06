data "archive_file" "sri_lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/sri_sg_check.py"
  output_path = "${path.module}/.build/sri_sg_check.zip"
}

resource "aws_iam_role" "sri_lambda_role" {
  name = "sri-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sri_lambda_logs" {
  role       = aws_iam_role.sri_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "sri_lambda_config" {
  role       = aws_iam_role.sri_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSConfigRulesExecutionRole"
}

resource "aws_lambda_function" "sri_sg_rule_lambda" {
  function_name    = "sri-sg-rule-lambda"
  role             = aws_iam_role.sri_lambda_role.arn
  runtime          = "python3.13"
  handler          = "sri_sg_check.handler"
  filename         = data.archive_file.sri_lambda_zip.output_path
  source_code_hash = data.archive_file.sri_lambda_zip.output_base64sha256
  timeout          = 30
}

resource "aws_lambda_permission" "sri_config_invoke" {
  statement_id  = "SriConfigInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sri_sg_rule_lambda.function_name
  principal     = "config.amazonaws.com"
}
