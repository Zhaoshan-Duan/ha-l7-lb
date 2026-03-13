# ElastiCache Redis for distributed LB state coordination.
# Single-node (cache.t3.micro) is sufficient for health status Pub/Sub.
# The LB's RedisManager auto-detects single-node vs. cluster mode.

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.service_name}-redis-subnet"
  subnet_ids = var.subnet_ids
}

resource "aws_elasticache_cluster" "this" {
  cluster_id           = "${var.service_name}-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  port                 = 6379
  security_group_ids   = [var.security_group_id]
  subnet_group_name    = aws_elasticache_subnet_group.this.name
}
