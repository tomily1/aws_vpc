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


resource "aws_iam_instance_profile" "ec2_instance_profile" {
  name = "EC2-IAM-Instance-Profile"
  role = aws_iam_role.ec2_iam_role.name
}

data "aws_ami" "launch_configuration_ami" {
  most_recent = true

  filter {
    name = "owner-alias"
    values = [ "amazon" ]
  }
}

resource "aws_launch_configuration" "ec2_private_launch_configuration" {
  image_id                    = data.aws_ami.launch_configuration_ami.id
  instance_type               = var.ec2_instance_type
  key_name                    = var.ec2_key_pair_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  security_groups             = [ aws_security_group.ec2_private_security_group.id ]

  user_data = <<EOF
  #!/bin/bash
  yum update -y
  yum install httpd24 -y
  service httpd start
  chkconfig httpd on
  export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
  echo "<html><body><h1>Hello from Production Backend at private instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
EOF
}

resource "aws_launch_configuration" "ec2_public_launch_configuration" {
  image_id                    = data.aws_ami.launch_configuration_ami.id
  instance_type               = var.ec2_instance_type
  key_name                    = var.ec2_key_pair_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  security_groups             = [ aws_security_group.ec2_public_security_group.id ]

  user_data = <<EOF
  #!/bin/bash
  yum update -y
  yum install httpd24 -y
  service httpd start
  chkconfig httpd on
  export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
  echo "<html><body><h1>Hello from Production Web App at public instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
EOF
}
