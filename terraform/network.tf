data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "sri" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "sri" {
  vpc_id = aws_vpc.sri.id

  tags = { Name = "${var.name}-igw" }
}


resource "aws_subnet" "satya" {
  vpc_id                  = aws_vpc.sri.id
  availability_zone       = data.aws_availability_zones.available.names[0]
  cidr_block              = cidrsubnet(var.vpc_cidr, 2, 0)
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-satya" }
}

resource "aws_route_table" "satya" {
  vpc_id = aws_vpc.sri.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sri.id
  }

  tags = { Name = "${var.name}-satya" }
}

resource "aws_route_table_association" "satya" {
  subnet_id      = aws_subnet.satya.id
  route_table_id = aws_route_table.satya.id
}
