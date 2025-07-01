data "vault_generic_secret" "redshift" {
  path = "secret/redshift"
}

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
  name               = "aws_batch_service_role"
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
  source                = "./modules/vpc/vpc"
  vpc_name              = "vpc"
  vpc_cidr_block        = "10.0.0.0/16"
  enable_dns_hostnames  = true
  enable_dns_support    = true
  internet_gateway_name = "vpc_igw"
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

# Redshift Security Group
module "redshift_sg" {
  source = "./modules/vpc/security_groups"
  vpc_id = module.vpc.vpc_id
  name   = "redshift-sg"
  ingress = [
    {
      from_port       = 5439
      to_port         = 5439
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

# Public Subnets
module "public_subnets" {
  source = "./modules/vpc/subnets"
  name   = "public-subnet"
  subnets = [
    {
      subnet = "10.0.1.0/24"
      az     = "us-east-1a"
    },
    {
      subnet = "10.0.2.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.3.0/24"
      az     = "us-east-1c"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = true
}

# Private Subnets
module "private_subnets" {
  source = "./modules/vpc/subnets"
  name   = "private-subnet"
  subnets = [
    {
      subnet = "10.0.6.0/24"
      az     = "us-east-1c"
    },
    {
      subnet = "10.0.5.0/24"
      az     = "us-east-1b"
    },
    {
      subnet = "10.0.4.0/24"
      az     = "us-east-1a"
    }
  ]
  vpc_id                  = module.vpc.vpc_id
  map_public_ip_on_launch = false
}

# Public Route Table
module "public_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "public-route-table"
  subnets = module.public_subnets.subnets[*]
  routes = [
    {
      cidr_block     = "0.0.0.0/0"
      nat_gateway_id = ""
      gateway_id     = module.vpc.igw_id
    }
  ]
  vpc_id = module.vpc.vpc_id
}

# Private Route Table
module "private_rt" {
  source  = "./modules/vpc/route_tables"
  name    = "private-route-table"
  subnets = module.private_subnets.subnets[*]
  routes  = []
  vpc_id  = module.vpc.vpc_id
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
      publicly_accessible = false
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
  compute_environment_name = "batch-compute"
  compute_resources {
    max_vcpus = 16

    security_group_ids = [
      module.security_group.id
    ]

    subnets = [
      module.public_subnets.subnets[0].id
    ]

    type = "FARGATE"
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
        name  = "REDSHIFT_USER"
        value = tostring(data.vault_generic_secret.redshift.data["username"])
      },
      {
        name  = "REDSHIFT_PASSWORD"
        value = tostring(data.vault_generic_secret.redshift.data["password"])
      },
      {
        name  = "REDSHIFT_HOST"
        value = ""
      },
      {
        name  = "REDSHIFT_PORT"
        value = "5439"
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
        "awslogs-group"         = "/aws/batch/job",
        "awslogs-region"        = "us-east-1",
        "awslogs-stream-prefix" = "ecs"
      }
    }
  })
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