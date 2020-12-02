provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {}
}

data "terraform_remote_state" "network_configuration" {
  backend = "s3"
  config {
    bucket = var.remote_state_bucket
    key    = var.remote_state_key
    region = var.region
  }
}

resource "aws_security_group" "ec2_public_security_group" {
  name        = "EC2-Public-SG"
  description = "Internet reaching access for EC2 Instances"
  vpc_id      = data.terraform_remote_state.network_configuration.vpc_id

  ingress = [{
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 80
    protocol = "TCP"
    to_port = 80
  },
  {
    cidr_blocks = [ "197.210.8.26/32" ]
    from_port = 22
    protocol = "TCP"
    to_port = 22
  }]

  egress = [ {
    from_port = 0
    ipv6_cidr_blocks = [ "0.0.0.0/0" ]
    protocol = "-1"
    to_port = 1
  } ]
}

resource "aws_security_group" "ec2_private_security_group" {
  name        = "EC2-Private-SG"
  description = "Only allow public SG resources to access these instances"
  vpc_id      = data.terraform_remote_state.network_configuration.vpc_id

  ingress = [ {
    from_port = 0
    protocol = "-1"
    cidr_blocks = [ aws_security_group.ec2_public_security_group.id ]
    to_port = 0
  },
  {
    from_port = 80
    protocol = "TCP"
    cidr_blocks = [ "0.0.0.0/0" ]
    to_port = 80
    description = "Allow health checking for instances using this SG"
  } ]

  egress = [ {
    from_port = 0
    ipv6_cidr_blocks = [ "0.0.0.0/0" ]
    protocol = "-1"
    to_port = 0
  } ]
}

resource "aws_security_group" "elb_security_group" {
  name = "ELB-SG"
  description = "ELB security group"
  vpc_id = data.terraform_remote_state.network_configuration.vpc_id

  ingress = [ {
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 0
    description = "Allow web traffic to load balancer"
    protocol = "-1"
    to_port = 0
  } ]

  egress = [ {
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 0
    description = "Allow web traffic from load balancer"
    protocol = "-1"
    to_port = 0
  } ]
}

resource "aws_iam_role" "ec2_iam_role" {
  name               = "EC2-IAM-Role"
  assume_role_policy = <<EOF
{
  "Version": "2020-12-02"
  "Statement":
  [
    {
      "Effect": "Allow",
      "Principal": {
        "Services": ["ec2.amazonaws.com", "application-autoscaling.amazonaws.com"]
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "ec2_iam_role_policy" {
  name   = "EC2-IAM-Role-Policy"
  role   = aws_iam_role.ec2_iam_role.id
  policy = <<EOF
{
  "Version": "2020-12-02",
  "Statement":
  [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "elasticloadbalancing:*",
        "cloudwatch:*",
        "logs:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}
