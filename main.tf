provider "aws" {
  region = "eu-north-1"
}

# VPC setup
resource "aws_vpc" "my_vpc" {
  cidr_block = "10.0.0.0/16"
}

# Subnets for the VPC
resource "aws_subnet" "private_subnet_1" {
  vpc_id = aws_vpc.my_vpc.id
  cidr_block = "10.0."
}