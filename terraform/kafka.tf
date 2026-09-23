data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# KRaft cluster ID: 16 random bytes, base64url without padding (22 chars).
resource "random_id" "cluster_id" {
  byte_length = 16
}

locals {
  # Fixed private IPs (x.x.N.10) so the static controller quorum is known before launch.
  broker_ips    = [for s in aws_subnet.public : cidrhost(s.cidr_block, 10)]
  quorum_voters = join(",", [for i, ip in local.broker_ips : "${i + 1}@${ip}:9093"])
  bootstrap     = join(",", [for ip in local.broker_ips : "${ip}:9092"])
}

resource "aws_security_group" "kafka" {
  name        = "${var.name}-brokers"
  description = "Kafka brokers and KRaft controllers"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${var.name}-brokers" }
}

resource "aws_vpc_security_group_ingress_rule" "client_vpc" {
  security_group_id = aws_security_group.kafka.id
  description       = "Kafka clients inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 9092
  to_port           = 9092
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_ingress_rule" "client_extra" {
  for_each = toset(var.client_cidrs)

  security_group_id = aws_security_group.kafka.id
  description       = "Kafka clients (extra CIDR)"
  ip_protocol       = "tcp"
  from_port         = 9092
  to_port           = 9092
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "controller" {
  security_group_id            = aws_security_group.kafka.id
  description                  = "KRaft controller quorum between nodes"
  ip_protocol                  = "tcp"
  from_port                    = 9093
  to_port                      = 9093
  referenced_security_group_id = aws_security_group.kafka.id
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.kafka.id
  description       = "Outbound for package and Kafka downloads, SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Instances are reached with SSM Session Manager, so there is no SSH key or port 22.
resource "aws_iam_role" "kafka" {
  name = "${var.name}-broker-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.kafka.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "kafka" {
  name = "${var.name}-broker-profile"
  role = aws_iam_role.kafka.name
}

resource "aws_instance" "broker" {
  count = var.broker_count

  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[count.index].id
  private_ip             = local.broker_ips[count.index]
  vpc_security_group_ids = [aws_security_group.kafka.id]
  iam_instance_profile   = aws_iam_instance_profile.kafka.name

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    kafka_version   = var.kafka_version
    node_id         = count.index + 1
    cluster_id      = random_id.cluster_id.b64_url
    quorum_voters   = local.quorum_voters
    advertised_host = local.broker_ips[count.index]
    heap_size       = var.heap_size
  })
  user_data_replace_on_change = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.volume_size_gb
    encrypted   = true
  }

  # A newer AMI must not silently replace a broker and wipe its data.
  lifecycle {
    ignore_changes = [ami]
  }

  # The bootstrap script downloads Kafka on first boot, so the internet route must exist.
  depends_on = [aws_route_table_association.public]

  tags = { Name = "${var.name}-broker-${count.index + 1}" }
}
