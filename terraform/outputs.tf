output "sri_vpc_id" {
  value = aws_vpc.sri_vpc.id
}

output "sri_kafka_instance_id" {
  value = aws_instance.sri_kafka.id
}

output "sri_kafka_bootstrap_servers" {
  value = "${aws_instance.sri_kafka.private_ip}:9092"
}

output "sri_kafka_secret_arn" {
  value = aws_secretsmanager_secret.sri_kafka_secret.arn
}
