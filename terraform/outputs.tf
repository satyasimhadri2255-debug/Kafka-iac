output "bootstrap_servers" {
  description = "Kafka bootstrap server (reachable from inside the VPC)."
  value       = "${aws_instance.kafka.private_ip}:9092"
}

output "instance_id" {
  description = "EC2 instance ID, for `aws ssm start-session --target <id>`."
  value       = aws_instance.kafka.id
}

output "cluster_id" {
  description = "KRaft cluster ID."
  value       = random_id.cluster_id.b64_url
}

output "kafka_admin_secret_arn" {
  description = "Secrets Manager secret with the SASL/SCRAM admin username and password."
  value       = aws_secretsmanager_secret.kafka_admin.arn
}

output "conformance_pack" {
  description = "AWS Config conformance pack with the security group controls."
  value       = aws_config_conformance_pack.sg_controls.name
}

output "vpc_id" {
  value = aws_vpc.sri.id
}
