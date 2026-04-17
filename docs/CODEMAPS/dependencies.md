<!-- Generated: 2026-04-11 | Files scanned: 22 | Token estimate: ~400 -->

# Dependencies

## Go Module

`github.com/karthikeyansura/ha-l7-lb` -- Go 1.25

## Direct Dependencies

| Package | Version | Purpose |
|---------|---------|---------|
| `github.com/redis/go-redis/v9` | v9.17.1 | Redis client (single-node + cluster), Pub/Sub |
| `gopkg.in/yaml.v3` | v3.0.1 | YAML config parsing with duration support |

## Indirect Dependencies

| Package | Version | Required By |
|---------|---------|-------------|
| `github.com/cespare/xxhash/v2` | v2.3.0 | go-redis |
| `github.com/dgryski/go-rendezvous` | v0.0.0-20200823014737 | go-redis |

## External Services

| Service | Protocol | Purpose | Required |
|---------|----------|---------|----------|
| AWS ElastiCache Redis | TCP 6379 | Cross-instance health state sync via Pub/Sub | No (degrades gracefully) |
| AWS Cloud Map DNS | DNS (UDP 53) | Backend service discovery (`api.internal`) | Yes (populates backend pool) |
| AWS NLB | TCP 8080 | L4 load distribution to LB ECS tasks | Yes (production entry point) |
| AWS ECR | HTTPS | Docker image registry | Yes (deployment) |
| AWS ECS Fargate | -- | Container orchestration | Yes (deployment) |

## Infrastructure (Terraform)

| Module | Purpose |
|--------|---------|
| `network` | VPC, subnets, security groups |
| `ecr` | ECR repositories (LB + backend) |
| `ecs-lb` | ECS service + task definition for LB |
| `ecs-backend` | ECS service + task definition for backends |
| `nlb` | Network Load Balancer + target group |
| `elasticache` | Redis cluster/single-node |
| `autoscaling` | ECS auto-scaling policies (CPU target 70%) |
| `logging` | CloudWatch log groups |
