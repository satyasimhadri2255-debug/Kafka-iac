# KRaft cluster ID: 16 random bytes, base64url without padding (22 chars).
resource "random_id" "cluster_id" {
  byte_length = 16
}

resource "aws_security_group" "kafka" {
  name        = "${var.name}-kafka"
  description = "Single-node Kafka (broker + KRaft controller)"
  vpc_id      = aws_vpc.sri.id

  tags = { Name = "${var.name}-kafka" }
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

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.kafka.id
  description       = "Outbound for package and Kafka downloads, SSM"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The instance is reached with SSM Session Manager, so there is no SSH key or port 22.
resource "aws_iam_role" "kafka" {
  name = "${var.name}-kafka-role"

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
  name = "${var.name}-kafka-profile"
  role = aws_iam_role.kafka.name
}

resource "aws_instance" "kafka" {
  # Amazon Linux 2023 x86_64 (al2023-ami-2023.12.20260918.0), us-east-2 only.
  ami                    = "ami-08be4b1b8afa29958"
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.satya.id
  vpc_security_group_ids = [aws_security_group.kafka.id]
  iam_instance_profile   = aws_iam_instance_profile.kafka.name

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    kafka_version = var.kafka_version
    cluster_id    = random_id.cluster_id.b64_url
    heap_size     = var.heap_size
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

  # The bootstrap script downloads Kafka on first boot, so the internet route must exist.
  depends_on = [aws_route_table_association.satya]

  tags = { Name = "${var.name}-kafka" }
}
