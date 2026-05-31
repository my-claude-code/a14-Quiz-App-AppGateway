output "agw_public_ip" {
  description = "Public IP of the Application Gateway — point your domain here"
  value       = azurerm_public_ip.agw.ip_address
}

output "vm_public_ip" {
  description = "Public IP of the VM — for SSH access only"
  value       = azurerm_public_ip.vm.ip_address
}

output "app_url" {
  description = "Quiz app URL"
  value       = "https://${var.domain}"
}

output "ssh_app" {
  description = "SSH command for the app VM"
  value       = "ssh ivansto@${azurerm_public_ip.vm.ip_address}"
}

output "entra_redirect_uri" {
  description = "Add this to your Entra app registration"
  value       = "https://${var.domain}/auth/callback"
}

output "ACTION_REQUIRED" {
  description = "Steps after deployment"
  value       = <<-EOT
    1. Point DNS: create A record ${var.domain} → ${azurerm_public_ip.agw.ip_address}
       (point to the AGW IP, NOT the VM IP)

    2. Add redirect URI to Entra app registration:
       https://${var.domain}/auth/callback

    3. Monitor VM setup:
       ssh ivansto@${azurerm_public_ip.vm.ip_address} 'tail -f /var/log/app-setup.log'

    4. Import question data (after VM setup complete):
       ssh ivansto@${azurerm_public_ip.vm.ip_address}
       cd /opt/quiz-app && source venv/bin/activate
       for f in data/english/*.json data/french/*.json data/defender_pam/*.json; do
           python utils/import_questions.py "$f"
       done
  EOT
}
