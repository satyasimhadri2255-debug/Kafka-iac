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
