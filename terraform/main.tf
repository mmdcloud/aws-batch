# IAM Role for AWS Batch Service
resource "aws_iam_role" "batch_service_role" {
  name = "aws_batch_service_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "batch.amazonaws.com"
        }
      }
    ]
  })
}

# IAM Role for ECS Tasks
resource "aws_iam_role" "ecs_task_role" {
  name = "ecs_task_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })
}

# Batch Compute Environment
resource "aws_batch_compute_environment" "batch_env" {
  compute_environment_name = "my-batch-compute-env"

  compute_resources {
    max_vcpus = 16
    min_vcpus = 0

    security_group_ids = [aws_security_group.batch_sg.id]
    subnets           = [aws_subnet.batch_subnet.id]
    type             = "FARGATE" # Or "EC2" for EC2 launch type

    instance_role = aws_iam_role.ecs_task_role.arn
  }

  service_role = aws_iam_role.batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.batch_service_role]
}

# Batch Job Queue
resource "aws_batch_job_queue" "batch_queue" {
  name     = "my-batch-job-queue"
  state    = "ENABLED"
  priority = 1 
  compute_environments = [aws_batch_compute_environment.batch_env.arn]
}

# Simple Batch Job Definition
resource "aws_batch_job_definition" "example_job" {
  name = "example-job-definition"
  type = "container"

  container_properties = jsonencode({
    command    = ["echo", "Hello from AWS Batch"]
    image      = "public.ecr.aws/amazonlinux/amazonlinux:latest"
    jobRoleArn = aws_iam_role.ecs_task_role.arn
    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }
    resourceRequirements = [
      {
        type  = "VCPU"
        value = "1"
      },
      {
        type  = "MEMORY"
        value = "2048"
      }
    ]
    executionRoleArn = aws_iam_role.ecs_task_role.arn
  })

  platform_capabilities = ["FARGATE"]
}

# Supporting Network Resources (minimal setup)
resource "aws_vpc" "batch_vpc" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "batch_subnet" {
  vpc_id     = aws_vpc.batch_vpc.id
  cidr_block = "10.0.1.0/24"
}

resource "aws_security_group" "batch_sg" {
  name   = "batch-security-group"
  vpc_id = aws_vpc.batch_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# IAM Policy Attachment
resource "aws_iam_role_policy_attachment" "batch_service_role" {
  role       = aws_iam_role.batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}