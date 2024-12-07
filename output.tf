output "public_ip_address" {
  description = "The public IP address of the NGINX server"
  value       = azurerm_public_ip.example.ip_address
}

output "ssh_command" {
  description = "SSH command to connect to the VM"
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.example.ip_address}"
}
