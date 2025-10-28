# -----------------------------------------------------------------------------------------
# Registering vault provider 
# -----------------------------------------------------------------------------------------
data "vault_generic_secret" "redshift" {
  path = "secret/redshift"
}

# -----------------------------------------------------------------------------------------
# IAM role for batch 
# -----------------------------------------------------------------------------------------
data "aws_iam_policy_document" "batch_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["batch.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "aws_batch_service_role" {
  name               = "aws-batch-service-role"
  assume_role_policy = data.aws_iam_policy_document.batch_assume_role.json
}

resource "aws_iam_role_policy_attachment" "aws_batch_service_role" {
  role       = aws_iam_role.aws_batch_service_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole"
}

# -----------------------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------------------
module "vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = false
  single_nat_gateway      = false
  one_nat_gateway_per_az  = false
  tags = {
    Project = "newsapp-batch"
  }
}

# Security Group
module "security_group" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "security-group"
  ingress = [
    {
      from_port       = 0
      to_port         = 0
      protocol        = "tcp"
      self            = "false"
      cidr_blocks     = ["0.0.0.0/0"]
      security_groups = []
      description     = "any"
    }
  ]
  egress = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    }
  ]
}

resource "aws_security_group" "security_group" {
  name   = "security-group"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
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
    Name = "security-group"
  }
}

resource "aws_security_group" "redshift_sg" {
  name   = "redshift-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    description = "Redshift Security Group"
    from_port   = 5439
    to_port     = 5439
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
    Name = "security-group"
  }
}

# -----------------------------------------------------------------------------------------
# ECR Configuration
# -----------------------------------------------------------------------------------------
module "ecr" {
  source               = "./modules/ecr"
  force_delete         = true
  scan_on_push         = false
  image_tag_mutability = "IMMUTABLE"
  bash_command         = "bash ${path.module}/../src/artifact_push.sh ${var.region}"
  name                 = "batch_job"
}

# -----------------------------------------------------------------------------------------
# Secrets Manager
# -----------------------------------------------------------------------------------------
module "db_credentials" {
  source                  = "./modules/secrets-manager"
  name                    = "rds-secrets"
  description             = "rds-secrets"
  recovery_window_in_days = 0
  secret_string = jsonencode({
    username = tostring(data.vault_generic_secret.redshift.data["username"])
    password = tostring(data.vault_generic_secret.redshift.data["password"])
  })
}

# -----------------------------------------------------------------------------------------
# Cloudwatch logs for Batch job
# -----------------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "batch_logs" {
  name              = "/aws/batch/job"
  retention_in_days = 7
}

# -----------------------------------------------------------------------------------------
# Redshift Configuration
# -----------------------------------------------------------------------------------------
module "redshift_serverless" {
  source              = "./modules/redshift"
  namespace_name      = "batch-namespace"
  admin_username      = tostring(data.vault_generic_secret.redshift.data["username"])
  admin_user_password = tostring(data.vault_generic_secret.redshift.data["password"])
  db_name             = "records"
  workgroups = [
    {
      workgroup_name      = "batch-workgroup"
      base_capacity       = 128
      publicly_accessible = true
      subnet_ids          = module.public_subnets.subnets[*].id
      security_group_ids  = [module.redshift_sg.id]
      config_parameters = [
        {
          parameter_key   = "enable_user_activity_logging"
          parameter_value = "true"
        }
      ]
    }
  ]
}

# -----------------------------------------------------------------------------------------
# Batch Configuration
# -----------------------------------------------------------------------------------------
resource "aws_batch_compute_environment" "batch_compute" {
  # name = "batch-compute"
  compute_resources {
    max_vcpus = 16

    security_group_ids = [
      module.security_group.id
    ]

    subnets = module.public_subnets.subnets[*].id
    type    = "FARGATE"
  }

  service_role = aws_iam_role.aws_batch_service_role.arn
  type         = "MANAGED"
  depends_on   = [aws_iam_role_policy_attachment.aws_batch_service_role]
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name               = "ecs_task_execution_role"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "ecr_registry_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_role_policy_attachment" "ecs_cloudwatch_logs" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess"
}

resource "aws_iam_role_policy" "secrets_manager_access" {
  name = "secrets_manager_access"
  role = aws_iam_role.ecs_task_execution_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = module.db_credentials.arn
      }
    ]
  })
}

resource "aws_batch_job_definition" "batch_job_definition" {
  name                  = "batch-job-definition"
  type                  = "container"
  platform_capabilities = ["FARGATE"]
  container_properties = jsonencode({
    image = "${module.ecr.repository_url}:latest",
    environment = [
      {
        name  = "REDSHIFT_DBNAME"
        value = "records"
      },
      {
        name  = "REDSHIFT_SECRET_NAME"
        value = module.db_credentials.name
      }
    ]
    jobRoleArn = aws_iam_role.ecs_task_execution_role.arn,
    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    },
    resourceRequirements = [
      { type = "VCPU", value = "0.25" },
      { type = "MEMORY", value = "512" }
    ],

    executionRoleArn = aws_iam_role.ecs_task_execution_role.arn,
    networkConfiguration = {
      assignPublicIp = "ENABLED"
    },
    logConfiguration = {
      logDriver = "awslogs",
      options = {
        "awslogs-group"         = "${aws_cloudwatch_log_group.batch_logs.name}",
        "awslogs-region"        = "us-east-1",
        "awslogs-stream-prefix" = "ecs"
      }
    }
  })
  depends_on = [aws_cloudwatch_log_group.batch_logs]
}

resource "aws_batch_job_queue" "batch_job_queue" {
  name     = "batch-job-queue"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.batch_compute.arn
  }
}
