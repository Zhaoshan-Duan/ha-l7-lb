# Outputs the endpoint as "address:port" for direct use as REDIS_ADDR.
output "redis_endpoint" {
  value = "${aws_elasticache_cluster.this.cache_nodes[0].address}:${aws_elasticache_cluster.this.cache_nodes[0].port}"
}
