output "bootstrap_servers" {
  description = "Kafka bootstrap servers (reachable from inside the VPC)."
  value       = local.bootstrap
}

output "broker_instance_ids" {
  description = "EC2 instance IDs, for `aws ssm start-session --target <id>`."
  value       = aws_instance.broker[*].id
}

output "cluster_id" {
  description = "KRaft cluster ID."
  value       = random_id.cluster_id.b64_url
}

output "vpc_id" {
  value = aws_vpc.this.id
}
