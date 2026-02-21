# ---------- coordination server ----------

output "headscale_url" {
  description = "Headscale server URL"
  value       = module.coordination_server.headscale_url
}

output "elastic_ip" {
  description = "Elastic IP of the coordination server"
  value       = module.coordination_server.elastic_ip
}

output "connect_command" {
  description = "Command for users to connect"
  value       = module.coordination_server.connect_command
}

output "ssm_connect" {
  description = "SSM command to connect to the coordination server"
  value       = module.coordination_server.ssm_connect
}

output "coordination_server_instance_id" {
  description = "EC2 instance ID of the coordination server"
  value       = module.coordination_server.instance_id
}

# ---------- prod subnet router ----------

output "subnet_router_instance_id" {
  description = "EC2 instance ID of the prod subnet router"
  value       = module.subnet_router.instance_id
}

output "subnet_router_private_ip" {
  description = "Private IP of the prod subnet router"
  value       = module.subnet_router.private_ip
}
