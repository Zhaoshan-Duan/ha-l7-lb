# Network Load Balancer (L4, TCP) fronting the custom L7 LB instances.
# NLB operates at L4 because the custom Go proxy IS the L7 layer.
# Using an ALB here would add unwanted HTTP processing overhead.

resource "aws_lb" "this" {
  name               = "${var.service_name}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.subnet_ids
}

# TCP target group: health checks use TCP (not HTTP) because the NLB
# only needs to verify the LB task is listening, not parse responses.
resource "aws_lb_target_group" "this" {
  name        = "${var.service_name}-lb-tg"
  port        = var.lb_port
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    port                = "traffic-port"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener on port 80: forwards all TCP traffic to the LB target group.
resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
