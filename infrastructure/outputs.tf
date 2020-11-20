output "vpc_id" {
  value = aws_vpc.production-vpc.id
}

output "vpc_cidr_block" {
  value = aws_vpc.production-vpc.cidr_block
}

output "public_subnet_1_cidr" {
  value = aws_subnet.public-subnet-1.id
}

output "public_subnet_2_cidr" {
  value = aws_subnet.public-subnet-2.id
}

output "public_subnet_3_cidr" {
  value = aws_subnet.public-subnet-3.id
}

output "private_subnet_1_cidr" {
  value = aws_subnet.private-subnet-1.id
}

output "private_subnet_2_cidr" {
  value = aws_subnet.private-subnet-2.id
}

output "private_subnet_3_cidr" {
  value = aws_subnet.private-subnet-3.id
}
