provider "aws" {
  region = var.region
}

terraform {
  backend "s3" {}
}

data "terraform_remote_state" "network_configuration" {
  backend = "s3"
  config = {
    bucket = var.remote_state_bucket
    key    = var.remote_state_key
    region = var.region
  }
}

resource "aws_security_group" "ec2_public_security_group" {
  name        = "EC2-Public-SG"
  description = "Internet reaching access for EC2 Instances"
  vpc_id      = data.terraform_remote_state.network_configuration.outputs.vpc_id

  ingress {
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 80
    protocol = "TCP"
    to_port = 80
  }

  ingress {
    cidr_blocks = [ "197.210.8.26/32" ]
    from_port = 22
    protocol = "TCP"
    to_port = 22
  }

  egress {
    from_port = 0
    cidr_blocks = [ "0.0.0.0/0" ]
    protocol = "-1"
    to_port = 0
  }
}

resource "aws_security_group" "ec2_private_security_group" {
  name        = "EC2-Private-SG"
  description = "Only allow public SG resources to access these instances"
  vpc_id      = data.terraform_remote_state.network_configuration.outputs.vpc_id

  ingress {
    from_port = 0
    protocol = "-1"
    security_groups = [ aws_security_group.ec2_public_security_group.id ]
    to_port = 0
  }

  ingress {
    from_port = 80
    protocol = "TCP"
    cidr_blocks = [ "0.0.0.0/0" ]
    to_port = 80
    description = "Allow health checking for instances using this SG"
  }

  egress {
    from_port = 0
    cidr_blocks = [ "0.0.0.0/0" ]
    protocol = "-1"
    to_port = 0
  }
}

resource "aws_security_group" "elb_security_group" {
  name = "ELB-SG"
  description = "ELB security group"
  vpc_id = data.terraform_remote_state.network_configuration.outputs.vpc_id

  ingress {
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 0
    description = "Allow web traffic to load balancer"
    protocol = "-1"
    to_port = 0
  }

  egress {
    cidr_blocks = [ "0.0.0.0/0" ]
    from_port = 0
    description = "Allow web traffic from load balancer"
    protocol = "-1"
    to_port = 0
  }
}

resource "aws_iam_role" "ec2_iam_role" {
  name               = "EC2-IAM-Role"
  assume_role_policy = <<EOF
{
  "Version" : "2012-10-17",
  "Statement" :
  [
    {
      "Effect" : "Allow",
      "Principal" : {
        "Service" : ["ec2.amazonaws.com", "application-autoscaling.amazonaws.com"]
      },
      "Action" : "sts:AssumeRole"
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
  "Version" : "2012-10-17",
  "Statement" : [
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
  owners = [ "amazon" ]
  most_recent = true # do not set to true but use custom ami so you don't destroy your instances everytime you launch.

  filter {
    name = "owner-alias"
    values = [ "amazon" ]
  }
}

resource "aws_launch_configuration" "ec2_private_launch_configuration" {
  image_id                    = "ami-0ce1e3f77cd41957e"
  instance_type               = var.ec2_instance_type
  key_name                    = var.ec2_key_pair_name
  associate_public_ip_address = false
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  security_groups             = [ aws_security_group.ec2_private_security_group.id ]

  user_data = <<EOF
  #!/bin/bash
  yum update -y
  yum install httpd -y
  service httpd start
  chkconfig httpd on
  export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
  echo "<html><body><h1>Hello from Production Backend at private instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
EOF
}

resource "aws_launch_configuration" "ec2_public_launch_configuration" {
  image_id                    = "ami-0ce1e3f77cd41957e"
  instance_type               = var.ec2_instance_type
  key_name                    = var.ec2_key_pair_name
  associate_public_ip_address = true
  iam_instance_profile        = aws_iam_instance_profile.ec2_instance_profile.name
  security_groups             = [ aws_security_group.ec2_public_security_group.id ]

  user_data = <<EOF
  #!/bin/bash
  yum update -y
  yum install httpd -y
  service httpd start
  chkconfig httpd on
  export INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
  echo "<html><body><h1>Hello from Production Web App at public instance <b>"$INSTANCE_ID"</b></h1></body></html>" > /var/www/html/index.html
EOF
}

resource "aws_elb" "webapp_load_balancer" {
  name            = "Production-WebApp-LoadBalancer"
  internal        = false
  security_groups = [ aws_security_group.elb_security_group.id ]
  subnets = [ 
    data.terraform_remote_state.network_configuration.outputs.public_subnet_1_cidr,
    data.terraform_remote_state.network_configuration.outputs.public_subnet_2_cidr,
    data.terraform_remote_state.network_configuration.outputs.public_subnet_3_cidr
  ]

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    healthy_threshold   = 5
    interval            = 30
    target              = "HTTP:80/index.html"
    timeout             = 10
    unhealthy_threshold = 5
  }
}

resource "aws_elb" "backend_load_balancer" {
  name            = "Production-Backend-LoadBalancer"
  internal        = true
  security_groups = [ aws_security_group.elb_security_group.id ]
  subnets = [ 
    data.terraform_remote_state.network_configuration.outputs.private_subnet_1_cidr,
    data.terraform_remote_state.network_configuration.outputs.private_subnet_2_cidr,
    data.terraform_remote_state.network_configuration.outputs.private_subnet_3_cidr
  ]

  listener {
    instance_port     = 80
    instance_protocol = "HTTP"
    lb_port           = 80
    lb_protocol       = "HTTP"
  }

  health_check {
    healthy_threshold   = 5
    interval            = 30
    target              = "HTTP:80/index.html"
    timeout             = 10
    unhealthy_threshold = 5
  }
}

resource "aws_autoscaling_group" "ec2_private_autoscaling_group" {
  name                = "Production-Backend-AutoScalingGroup"
  vpc_zone_identifier = [
    data.terraform_remote_state.network_configuration.outputs.private_subnet_1_cidr,
    data.terraform_remote_state.network_configuration.outputs.private_subnet_2_cidr,
    data.terraform_remote_state.network_configuration.outputs.private_subnet_3_cidr
  ]

  max_size             = var.max_instance_size
  min_size             = var.min_instance_size
  launch_configuration = aws_launch_configuration.ec2_private_launch_configuration.name
  health_check_type = "ELB"
  load_balancers = [ aws_elb.backend_load_balancer.name ]

  tags = [
    {
      key                 = "Name"
      propagate_at_launch = false
      value               = "Backend-EC2-Instance"
    },
    {
      key                 = "Type"
      propagate_at_launch = false
      value               = "Production"
    }
  ]
}

resource "aws_autoscaling_group" "ec2_public_autoscaling_group" {
  name                = "Production-WebApp-AutoScalingGroup"
  vpc_zone_identifier = [
    data.terraform_remote_state.network_configuration.outputs.public_subnet_1_cidr,
    data.terraform_remote_state.network_configuration.outputs.public_subnet_2_cidr,
    data.terraform_remote_state.network_configuration.outputs.public_subnet_3_cidr
  ]

  max_size             = var.max_instance_size
  min_size             = var.min_instance_size
  launch_configuration = aws_launch_configuration.ec2_public_launch_configuration.name
  health_check_type = "ELB"
  load_balancers = [ aws_elb.webapp_load_balancer.name ]

  depends_on = [aws_launch_configuration.ec2_public_launch_configuration]

  tags = [
    {
      key                 = "Name"
      propagate_at_launch = false
      value               = "WebApp-EC2-Instance"
    },
    {
      key                 = "Type"
      propagate_at_launch = false
      value               = "WebApp"
    }
  ]
}

resource "aws_autoscaling_policy" "webapp_production_scaling_policy" {
  autoscaling_group_name   = aws_autoscaling_group.ec2_public_autoscaling_group.name
  name                     = "Production-WebApp-AutoScaling-Policy"
  policy_type              = "TargetTrackingScaling"
  min_adjustment_magnitude = 1

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }
}

resource "aws_autoscaling_policy" "backend_production_scaling_policy" {
  autoscaling_group_name   = aws_autoscaling_group.ec2_private_autoscaling_group.name
  name                     = "Production-Backend-AutoScaling-Policy"
  policy_type              = "TargetTrackingScaling"
  min_adjustment_magnitude = 1

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 80.0
  }
}

resource "aws_sns_topic" "webapp_production_autoscaling_alert_topic" {
  display_name = "WebApp-AutoScaling-Topic"
  name         = "WebApp-AutoScaling-Topic"
}

resource "aws_sns_topic_subscription" "webapp_production_autoscaling_sms_subscription" {
  endpoint = "+2348133058722"
  protocol = "sms"
  topic_arn = aws_sns_topic.webapp_production_autoscaling_alert_topic.arn
}

resource "aws_autoscaling_notification" "webapp_production_autoscaling_notification" {
  group_names   = [ aws_autoscaling_group.ec2_public_autoscaling_group.name ]
  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR"
  ]
  topic_arn = aws_sns_topic.webapp_production_autoscaling_alert_topic.arn
}
