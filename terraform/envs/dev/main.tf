provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project = "tinyuka-2025-capstone"
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "project-bedrock-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "kubernetes.io/cluster/project-bedrock-cluster" = "shared"
  }

  tags = { Project = "tinyuka-2025-capstone" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "project-bedrock-cluster"
  cluster_version = "1.33"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      instance_types = ["t3.small"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
      subnet_ids     = module.vpc.private_subnets
    }
  }

  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  authentication_mode = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_security_group" "rds" {
  name   = "bedrock-rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_db_subnet_group" "bedrock" {
  name       = "bedrock-db-subnets"
  subnet_ids = module.vpc.private_subnets
  tags       = { Project = "tinyuka-2025-capstone" }
}

resource "random_password" "mysql" {
  length  = 20
  special = false
}

resource "random_password" "postgres" {
  length  = 20
  special = false
}

resource "aws_db_instance" "catalog_mysql" {
  identifier              = "bedrock-catalog-mysql"
  engine                  = "mysql"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = "catalog"
  username                = "admin"
  password                = random_password.mysql.result
  db_subnet_group_name    = aws_db_subnet_group.bedrock.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 1

  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_db_instance" "orders_postgres" {
  identifier              = "bedrock-orders-postgres"
  engine                  = "postgres"
  instance_class          = "db.t4g.micro"
  allocated_storage       = 20
  db_name                 = "orders"
  username                = "dbadmin"
  password                = random_password.postgres.result
  db_subnet_group_name    = aws_db_subnet_group.bedrock.name
  vpc_security_group_ids  = [aws_security_group.rds.id]
  publicly_accessible     = false
  skip_final_snapshot     = true
  backup_retention_period = 1

  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_dynamodb_table" "carts" {
  name         = "bedrock-carts"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "customerId"
    type = "S"
  }

  global_secondary_index {
    name            = "idx_global_customerId"
    hash_key        = "customerId"
    projection_type = "ALL"
  }

  tags = { Project = "tinyuka-2025-capstone" }
}


resource "aws_secretsmanager_secret" "mysql" {
  name = "bedrock/mysql"
  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_secretsmanager_secret_version" "mysql" {
  secret_id = aws_secretsmanager_secret.mysql.id
  secret_string = jsonencode({
    username = "admin"
    password = random_password.mysql.result
    host     = aws_db_instance.catalog_mysql.address
    port     = 3306
    dbname   = "catalog"
  })
}

resource "aws_secretsmanager_secret" "postgres" {
  name = "bedrock/postgres"
  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_secretsmanager_secret_version" "postgres" {
  secret_id = aws_secretsmanager_secret.postgres.id
  secret_string = jsonencode({
    username = "dbadmin"
    password = random_password.postgres.result
    host     = aws_db_instance.orders_postgres.address
    port     = 5432
    dbname   = "orders"
  })
}

resource "aws_s3_bucket" "assets" {
  bucket = "bedrock-assets-alt-soe-tin-025-0082-v2"
  tags   = { Project = "tinyuka-2025-capstone" }
}

resource "aws_s3_bucket_public_access_block" "assets" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "lambda_exec" {
  name = "bedrock-asset-processor-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = { Project = "tinyuka-2025-capstone" }
}

resource "aws_iam_role_policy" "lambda_exec" {
  role = aws_iam_role.lambda_exec.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.assets.arn}/*"
      }
    ]
  })
}

resource "aws_lambda_function" "processor" {
  function_name    = "bedrock-asset-processor"
  role              = aws_iam_role.lambda_exec.arn
  handler           = "handler.handler"
  runtime           = "python3.12"
  filename          = "../../../lambda/handler.zip"
  source_code_hash  = filebase64sha256("../../../lambda/handler.zip")
  tags              = { Project = "tinyuka-2025-capstone" }
}

resource "aws_lambda_permission" "s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.assets.arn
}

resource "aws_s3_bucket_notification" "assets" {
  bucket = aws_s3_bucket.assets.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.processor.arn
    events               = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_lambda_permission.s3_invoke]
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "region" {
  value = "us-east-1"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "assets_bucket_name" {
  value = aws_s3_bucket.assets.bucket
}
# retest
