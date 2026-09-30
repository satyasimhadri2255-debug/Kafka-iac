# SCRAM credentials for the Kafka client listener. The password is generated here and
# stored only in Secrets Manager; the instance fetches it at boot with its IAM role,
# so it never appears in user data, tfvars or outputs.
resource "random_password" "kafka_admin" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "kafka_admin" {
  name_prefix             = "${var.name}/kafka-admin-"
  description             = "SASL/SCRAM-SHA-512 admin credentials for the ${var.name} Kafka broker"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "kafka_admin" {
  secret_id = aws_secretsmanager_secret.kafka_admin.id
  secret_string = jsonencode({
    username = var.kafka_admin_user
    password = random_password.kafka_admin.result
  })
}

resource "aws_iam_role_policy" "kafka_secret" {
  name = "read-kafka-admin-secret"
  role = aws_iam_role.kafka.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.kafka_admin.arn
    }]
  })
}
