output "instance_id" {
  description = "EC2 instance ID"
  value       = module.coordination_server.instance_id
}

output "elastic_ip" {
  description = "Elastic IP address"
  value       = module.coordination_server.elastic_ip
}

output "headscale_url" {
  description = "Headscale server URL"
  value       = module.coordination_server.headscale_url
}

output "connect_command" {
  description = "Command for users to connect"
  value       = module.coordination_server.connect_command
}

output "ssm_connect" {
  description = "SSM command to connect to instance"
  value       = module.coordination_server.ssm_connect
}

output "security_group_id" {
  description = "Security group ID"
  value       = module.coordination_server.security_group_id
}

output "log_group" {
  description = "CloudWatch log group for audit logs"
  value       = module.coordination_server.log_group
}
