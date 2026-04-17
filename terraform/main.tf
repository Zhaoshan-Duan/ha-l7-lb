# Root module: composes all infrastructure from focused sub-modules.
#
# Architecture:
#   Client -> NLB (L4, TCP) -> LB ECS tasks (L7, custom proxy) -> Backend ECS tasks
#                                    |
#                              ElastiCache Redis (state coordination)

module "network" {
  source         = "./modules/network"
  service_name   = var.service_name
  container_port = var.backend_port
  lb_port        = var.lb_port
  redis_port     = 6379
}

module "ecr_lb" {
  source          = "./modules/ecr"
  repository_name = "${var.service_name}-lb"
}

module "ecr_backend" {
  source          = "./modules/ecr"
  repository_name = "${var.service_name}-backend"
}

module "logging" {
  source            = "./modules/logging"
  service_name      = var.service_name
  retention_in_days = var.log_retention_days
}

data "aws_iam_role" "execution_role" {
  name = "ecsTaskExecutionRole"
}

module "elasticache" {
  source            = "./modules/elasticache"
  service_name      = var.service_name
  subnet_ids        = module.network.subnet_ids
  security_group_id = module.network.redis_security_group_id
}

module "nlb" {
  source       = "./modules/nlb"
  service_name = var.service_name
  vpc_id       = module.network.vpc_id
  subnet_ids   = module.network.subnet_ids
  lb_port      = var.lb_port
}

# Private DNS namespace for backend service discovery.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name        = "internal"
  description = "Private DNS for HA L7 LB backend discovery"
  vpc         = module.network.vpc_id
}

# --- Dynamic Scalable Backend ---

# A single Cloud Map service. All backend tasks will register here.
resource "aws_service_discovery_service" "backend" {
  name = "api"
  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
  }
}

# The unified ECS backend cluster
module "ecs_backend" {
  source               = "./modules/ecs-backend"
  service_name         = "api-backend"
  image                = "${module.ecr_backend.repository_url}:latest"
  container_port       = var.backend_port
  subnet_ids           = module.network.subnet_ids
  security_group_ids   = [module.network.backend_security_group_id]
  execution_role_arn   = data.aws_iam_role.execution_role.arn
  task_role_arn        = data.aws_iam_role.execution_role.arn
  log_group_name       = module.logging.log_group_name
  ecs_count            = var.backend_min
  region               = var.aws_region
  service_registry_arn = aws_service_discovery_service.backend.arn
  depends_on           = [docker_registry_image.backend]
}

# Autoscaling policy linked to the unified backend cluster
module "autoscaling_backend" {
  source           = "./modules/autoscaling"
  service_name     = "api-backend"
  ecs_cluster_name = module.ecs_backend.cluster_name
  ecs_service_name = module.ecs_backend.service_name
  min_capacity     = var.backend_min
  max_capacity     = var.backend_max
  cpu_target_value = var.cpu_target_value
}

# --- Load Balancer ---

module "ecs_lb" {
  source             = "./modules/ecs-lb"
  service_name       = "${var.service_name}-lb"
  image              = "${module.ecr_lb.repository_url}:latest"
  container_port     = var.lb_port
  subnet_ids         = module.network.subnet_ids
  security_group_ids = [module.network.lb_security_group_id]
  execution_role_arn = data.aws_iam_role.execution_role.arn
  task_role_arn      = data.aws_iam_role.execution_role.arn
  log_group_name     = module.logging.log_group_name
  ecs_count          = var.lb_count
  region             = var.aws_region
  target_group_arn   = module.nlb.target_group_arn
  redis_addr         = module.elasticache.redis_endpoint
  retries_enabled    = var.retries_enabled
  depends_on         = [docker_registry_image.lb]
}

# --- Docker Builds ---

resource "docker_image" "lb" {
  name = "${module.ecr_lb.repository_url}:latest"
  build {
    context    = "../"
    dockerfile = "Dockerfile.lb"
  }
}

resource "docker_registry_image" "lb" {
  name = docker_image.lb.name
}

resource "docker_image" "backend" {
  name = "${module.ecr_backend.repository_url}:latest"
  build {
    context    = "../"
    dockerfile = "Dockerfile.backend"
  }
}

resource "docker_registry_image" "backend" {
  name = docker_image.backend.name
}

# --- Locust Load Generator ---
#
# Single EC2 in the default VPC that runs Locust in headless mode.
# Driven remotely via `aws ssm send-command`; results land in S3.

module "locust" {
  source               = "./modules/locust"
  service_name         = var.service_name
  vpc_id               = module.network.vpc_id
  subnet_id            = module.network.subnet_ids[0]
  nlb_dns_name         = module.nlb.nlb_dns_name
  lb_security_group_id = module.network.lb_security_group_id
}