resource "random_password" "sri_kafka_password" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "sri_kafka_secret" {
  name                    = "sri-kafka-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "sri_kafka_secret_value" {
  secret_id = aws_secretsmanager_secret.sri_kafka_secret.id
  secret_string = jsonencode({
    username = "sri-kafka-admin"
    password = random_password.sri_kafka_password.result
  })
}

resource "aws_iam_role_policy" "sri_kafka_secret_access" {
  name = "sri-kafka-secret-access"
  role = aws_iam_role.sri_kafka_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.sri_kafka_secret.arn
    }]
  })
}
