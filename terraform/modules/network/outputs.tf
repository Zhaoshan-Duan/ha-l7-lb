output "vpc_id" { value = data.aws_vpc.default.id }
output "subnet_ids" { value = data.aws_subnets.default.ids }
output "backend_security_group_id" { value = aws_security_group.backend.id }
output "lb_security_group_id" { value = aws_security_group.lb.id }
output "redis_security_group_id" { value = aws_security_group.redis.id }
