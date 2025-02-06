provider "aws" {
  region = var.region
}

variable "region" {
  description = "AWS Region to deploy resources"
  type        = string
  default     = "ap-south-1"
}

variable "key_name" {
  description = "Name of an existing EC2 KeyPair to enable SSH access to the instance"
  type        = string
}

data "aws_availability_zones" "available" {}

# Create VPC
resource "aws_vpc" "my_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "MyVPC"
  }
}

# Create two public subnets in different availability zones
resource "aws_subnet" "public_subnet1" {
  vpc_id                  = aws_vpc.my_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false

  tags = {
    Name = "PublicSubnet1"
  }
}

resource "aws_subnet" "public_subnet2" {
  vpc_id                  = aws_vpc.my_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false

  tags = {
    Name = "PublicSubnet2"
  }
}

# Allocate an Elastic IP for use in the VPC
resource "aws_eip" "elastic_ip" {
  vpc = true
}

# Create an Internet Gateway and attach it to the VPC
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "MyIGW"
  }
}

# Create a public route table for the VPC
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.my_vpc.id

  tags = {
    Name = "PublicRouteTable"
  }
}

# Create a default route to the Internet Gateway
resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

# Associate the public route table with each public subnet
resource "aws_route_table_association" "a1" {
  subnet_id      = aws_subnet.public_subnet1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "a2" {
  subnet_id      = aws_subnet.public_subnet2.id
  route_table_id = aws_route_table.public_rt.id
}

# Security Group for the Application Load Balancer (ALB)
resource "aws_security_group" "load_balancer_sg" {
  name        = "load_balancer_sg"
  description = "Allow HTTP from the world"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "LoadBalancerSG"
  }
}

# Security Group for the EC2 instance to allow HTTP from the Load Balancer
resource "aws_security_group" "ec2_instance_sg" {
  name        = "ec2_instance_sg"
  description = "Allow HTTP from Load Balancer"
  vpc_id      = aws_vpc.my_vpc.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.load_balancer_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "EC2InstanceSG"
  }
}

# Security Group for SSH access (initially with no ingress rules)
resource "aws_security_group" "ec2_ssh_access_sg" {
  name        = "ec2_ssh_access_sg"
  description = "Allow SSH access to EC2 instance (add IP manually)"
  vpc_id      = aws_vpc.my_vpc.id

  # No ingress rules by default

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "EC2SSHAccessSG"
  }
}

# Launch an EC2 instance
resource "aws_instance" "ec2_instance" {
  ami                         = "ami-02972a2a0ac299bb7"  # Amazon Linux 2 AMI
  instance_type               = "t2.micro"
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public_subnet1.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [
    aws_security_group.ec2_instance_sg.id,
    aws_security_group.ec2_ssh_access_sg.id
  ]

  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y httpd
    yum install -y ec2-instance-connect
    systemctl start httpd
    systemctl enable httpd
    echo "<h1>Welcome to the EC2 Instance</h1>" > /var/www/html/index.html
  EOF

  tags = {
    Name = "EC2Instance"
  }
}

# Associate the allocated Elastic IP with the EC2 instance
resource "aws_eip_association" "eip_assoc" {
  allocation_id = aws_eip.elastic_ip.id
  instance_id   = aws_instance.ec2_instance.id
}

# Create an Application Load Balancer (ALB)
resource "aws_lb" "application_load_balancer" {
  name               = "MyALB"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.load_balancer_sg.id]
  subnets            = [aws_subnet.public_subnet1.id, aws_subnet.public_subnet2.id]

  tags = {
    Name = "MyALB"
  }
}

# Create a Target Group and register the EC2 instance
resource "aws_lb_target_group" "target_group" {
  name        = "target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = aws_vpc.my_vpc.id

  health_check {
    protocol = "HTTP"
    port     = "traffic-port"
    path     = "/"
    matcher  = "200"
  }

  tags = {
    Name = "TargetGroup"
  }
}

# Attach the EC2 instance to the target group
resource "aws_lb_target_group_attachment" "target_attachment" {
  target_group_arn = aws_lb_target_group.target_group.arn
  target_id        = aws_instance.ec2_instance.id
  port             = 80
}

# Create a Listener for the ALB that forwards HTTP traffic to the target group
resource "aws_lb_listener" "alb_listener" {
  load_balancer_arn = aws_lb.application_load_balancer.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.target_group.arn
  }
}

# Outputs for ALB DNS name and the Elastic IP (for troubleshooting)
output "load_balancer_dns_name" {
  description = "The DNS name of the load balancer"
  value       = aws_lb.application_load_balancer.dns_name
}

output "public_ip" {
  description = "Public IP for troubleshooting"
  value       = aws_eip.elastic_ip.public_ip
}
