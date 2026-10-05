data "aws_vpc" "sri_default_vpc" {
  default = true
}

resource "aws_security_group" "sri_kafka_sg" {
  name   = "sri-kafka-sg"
  vpc_id = data.aws_vpc.sri_default_vpc.id

  ingress {
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.sri_default_vpc.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "sri_kafka_role" {
  name = "sri-kafka-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "sri_kafka_ssm" {
  role       = aws_iam_role.sri_kafka_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "sri_kafka_profile" {
  name = "sri-kafka-profile"
  role = aws_iam_role.sri_kafka_role.name
}

resource "aws_instance" "sri_kafka" {
  ami                    = "ami-08be4b1b8afa29958"
  instance_type          = "c7i-flex.large"
  vpc_security_group_ids = [aws_security_group.sri_kafka_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.sri_kafka_profile.name

  user_data = templatefile("${path.module}/templates/bootstrap.sh.tftpl", {
    secret_arn = aws_secretsmanager_secret.sri_kafka_secret.arn
  })

  tags = { Name = "sri-kafka" }

  depends_on = [
    aws_secretsmanager_secret_version.sri_kafka_secret_value,
    aws_iam_role_policy.sri_kafka_secret_access,
  ]
}
