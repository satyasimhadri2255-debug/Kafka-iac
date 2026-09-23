variable "region" {
  description = "AWS region to deploy into (must have at least 3 availability zones)."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "kafka-tf"
}

variable "vpc_cidr" {
  description = "CIDR block for the Kafka VPC. Each broker gets a /24 subnet carved from it."
  type        = string
  default     = "10.0.0.0/16"
}

variable "broker_count" {
  description = "Number of Kafka nodes (each runs broker + KRaft controller). Use an odd number >= 3."
  type        = number
  default     = 3

  validation {
    condition     = var.broker_count >= 3 && var.broker_count % 2 == 1
    error_message = "broker_count must be an odd number >= 3 so the KRaft quorum can tolerate failures."
  }
}

variable "instance_type" {
  description = "EC2 instance type for Kafka nodes."
  type        = string
  default     = "t3.medium"
}

variable "heap_size" {
  description = "JVM heap for each Kafka node (e.g. 1g). Keep it well under instance memory."
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
