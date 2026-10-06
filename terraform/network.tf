resource "aws_vpc" "sri_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "sri-vpc" }
}

resource "aws_internet_gateway" "sri_igw" {
  vpc_id = aws_vpc.sri_vpc.id

  tags = { Name = "sri-igw" }
}

resource "aws_subnet" "sri_public_subnet" {
  vpc_id                  = aws_vpc.sri_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-2a"
  map_public_ip_on_launch = true

  tags = { Name = "sri-public-subnet" }
}

resource "aws_route_table" "sri_public_rt" {
  vpc_id = aws_vpc.sri_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.sri_igw.id
  }

  tags = { Name = "sri-public-rt" }
}

resource "aws_route_table_association" "sri_public_rt_assoc" {
  subnet_id      = aws_subnet.sri_public_subnet.id
  route_table_id = aws_route_table.sri_public_rt.id
}
