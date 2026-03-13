variable "service_name" {
  type = string
}

variable "container_port" {
  type = number
}

variable "lb_port" {
  type = number
}

variable "redis_port" {
  type    = number
  default = 6379
}