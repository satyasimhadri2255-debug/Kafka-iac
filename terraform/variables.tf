variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "sri-kafka-tf"
}

variable "vpc_cidr" {
  description = "CIDR block for the Kafka VPC."
  type        = string
  default     = "10.0.0.0/24"
}

variable "instance_type" {
  description = "EC2 instance type for the Kafka node."
  type        = string
  default     = "c7i-flex.large"
}

variable "heap_size" {
  description = "JVM heap for Kafka (e.g. 1g). Keep it well under instance memory."
  type        = string
  default     = "1g"
}

variable "volume_size_gb" {
  description = "Root EBS volume size (GiB); Kafka data lives on this volume."
  type        = number
  default     = 30
}

variable "kafka_version" {
  description = "Apache Kafka version (Apache CDN, falls back to archive.apache.org)."
  type        = string
  default     = "4.3.1"
}

variable "client_cidrs" {
  description = "Extra CIDRs allowed to reach the Kafka client port (9092). The VPC CIDR is always allowed."
  type        = list(string)
  default     = []
}

variable "kafka_admin_user" {
  description = "SASL/SCRAM username for the Kafka admin. The password is generated and stored in Secrets Manager."
  type        = string
  default     = "kafka-admin"
}

variable "create_config_recorder" {
  description = "Create an AWS Config recorder and delivery channel. Set false if Config is already recording in this account/region (e.g. Control Tower)."
  type        = bool
  default     = true
}

variable "restricted_ports" {
  description = "Ports that must never be open to 0.0.0.0/0 or ::/0. Matching ingress rules are revoked automatically."
  type        = list(number)
  default     = [22, 3389, 9092, 9093]
}

variable "automatic_remediation" {
  description = "Revoke world-open ingress on restricted_ports automatically. If false, the rule only reports and remediation is manual."
  type        = bool
  default     = true
}
