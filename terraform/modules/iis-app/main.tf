locals {
  app_hostname                 = "${lower(var.resource_environment)}apphost"
  app_dns_name                 = "${lower(var.resource_environment)}app_web_vm"
  db_hostname                  = "${lower(var.resource_environment)}dbhost"
  db_dns_name                  = "${lower(var.resource_environment)}db_web_vm"
  resource_group_name_short    = substr(lower(replace(var.resource_group,"-","")),0,20)
  vdc_resource_group_name      = element(split("/",var.vdc_resource_group_id),length(split("/",var.vdc_resource_group_id))-1)
}

resource "azurerm_resource_group" "app_rg" {
  name                         = var.resource_group
  location                     = var.location

  tags                         = var.tags
}

resource "azurerm_role_assignment" "demo_admin" {
  scope                        = azurerm_resource_group.app_rg.id
  role_definition_name         = "Contributor"
  principal_id                 = var.admin_object_id

  count                        = var.admin_object_id != null ? 1 : 0
}

resource azurerm_role_assignment vm_admin {
  scope                        = azurerm_resource_group.app_rg.id
  role_definition_name         = "Virtual Machine Administrator Login"
  principal_id                 = var.admin_object_id

  count                        = var.admin_object_id != null ? 1 : 0
}

# Adapted from https://github.com/Azure/terraform-azurerm-diskencrypt/blob/master/main.tf
resource azurerm_key_vault_key disk_encryption_key {
  name                         = "${azurerm_resource_group.app_rg.name}-disk-key"
  key_vault_id                 = var.key_vault_id
  key_type                     = "RSA"
  key_size                     = 2048
  key_opts                     = [
                                "decrypt",
                                "encrypt",
                                "sign",
                                "unwrapKey",
                                "verify",
                                "wrapKey",
  ]

  depends_on                   = [var.vm_connectivity_dependency]
}


resource azurerm_storage_container scripts {
  name                         = "paasappscripts"
  storage_account_name         = var.automation_storage_name
  container_access_type        = "container"
}

resource azurerm_storage_blob install_agent_script {
  name                         = "install_agent.ps1"
  storage_account_name         = var.automation_storage_name
  storage_container_name       = azurerm_storage_container.scripts.name

  type                         = "Block"
  source                       = "${path.module}/scripts/host/install_agent.ps1"
}

resource azurerm_storage_blob mount_data_disks_script {
  name                         = "mount_data_disks.ps1"
  storage_account_name         = var.automation_storage_name
  storage_container_name       = azurerm_storage_container.scripts.name

  type                         = "Block"
  source                       = "${path.module}/scripts/host/mount_data_disks.ps1"
}

resource "azurerm_network_interface" "app_web_if" {
  name                         = "${azurerm_resource_group.app_rg.name}-web-vm${count.index+1}-nic"
  location                     = azurerm_resource_group.app_rg.location
  resource_group_name          = azurerm_resource_group.app_rg.name
  count                        = var.app_web_vm_number

  ip_configuration {
    name                       = "app_web_ipconfig"
    subnet_id                  = var.app_subnet_id
    private_ip_address         = element(var.app_web_vms, count.index)
    private_ip_address_allocation = "Static"
  }

  tags                         = var.tags
}

resource "azurerm_virtual_machine" "app_web_vm" {
  name                         = "${azurerm_resource_group.app_rg.name}-web-vm${count.index+1}"
  location                     = azurerm_resource_group.app_rg.location
  resource_group_name          = azurerm_resource_group.app_rg.name
  vm_size                      = var.app_web_vm_size
  network_interface_ids        = [element(azurerm_network_interface.app_web_if.*.id, count.index)]
  # Make zone redundant
  zones                        = [(count.index % 3) + 1]
  count                        = var.app_web_vm_number

  storage_image_reference {
    publisher                  = var.app_web_image_publisher
    offer                      = var.app_web_image_offer
    sku                        = var.app_web_image_sku
    version                    = var.app_web_image_version
  }
  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true

  storage_os_disk {
    name                       = "${azurerm_resource_group.app_rg.name}-web-vm${count.index+1}-osdisk"
    caching                    = "ReadWrite"
    create_option              = "FromImage"
    managed_disk_type          = "Premium_LRS"
  }

 # Optional data disks
  storage_data_disk {
    name                       = "${azurerm_resource_group.app_rg.name}-web-vm${count.index+1}-datadisk"
    caching                    = "ReadWrite"
    managed_disk_type          = "Premium_LRS"
    create_option              = "Empty"
    lun                        = 0
    disk_size_gb               = "255"
  }

  os_profile {
    computer_name              = "${local.app_hostname}${count.index+1}"
    admin_username             = var.admin_username
    admin_password             = var.admin_password
  }

  os_profile_windows_config {
    provision_vm_agent         = true
    enable_automatic_upgrades  = true
  }
    
  # Required for AAD Login
  identity {
    type                       = "SystemAssigned"
  }

  timeouts {
    create                     = var.default_create_timeout
    update                     = var.default_update_timeout
    read                       = var.default_read_timeout
    delete                     = var.default_delete_timeout
  }  

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )
}

resource null_resource start_web_vm {
  # Always run this
  triggers                     = {
    always_run                 = timestamp()
  }

  provisioner local-exec {
    # Start VM, so we can execute script through SSH
    command                    = "az vm start --ids ${azurerm_virtual_machine.app_web_vm[count.index].id}"
  }

  count                        = var.app_web_vm_number
}

resource azurerm_virtual_machine_extension app_web_vm_monitor {
  name                         = "MMAExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.EnterpriseCloud.Monitoring"
  type                         = "MicrosoftMonitoringAgent"
  type_handler_version         = "1.0"
  auto_upgrade_minor_version   = true
  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }
  settings                     = <<EOF
    {
      "workspaceId"            : "${var.diagnostics_workspace_workspace_id}",
      "azureResourceId"        : "${element(azurerm_virtual_machine.app_web_vm.*.id, count.index)}",
      "stopOnMultipleConnections": "true"
    }
  EOF
  protected_settings = <<EOF
    { 
      "workspaceKey"           : "${var.diagnostics_workspace_key}"
    } 
  EOF

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

# count                        = var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  count                        = var.app_web_vm_number

  depends_on                   = [null_resource.start_web_vm]
}
resource azurerm_virtual_machine_extension app_db_web_aadlogin {
  name                         = "AADLoginForWindows"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.ActiveDirectory"
  type                         = "AADLoginForWindows"
  type_handler_version         = "1.0"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  tags                         = var.tags
  depends_on                   = [null_resource.start_web_vm]
} 
resource "azurerm_virtual_machine_extension" "app_web_vm_pipeline_deployment_group" {
  name                         = "TeamServicesAgentExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.VisualStudio.Services"
  type                         = "TeamServicesAgent"
  type_handler_version         = "1.26"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "VSTSAccountName": "${var.app_devops["account"]}",        
      "TeamProject": "${var.app_devops["team_project"]}",
      "DeploymentGroup": "${var.app_devops["web_deployment_group"]}",
      "AgentName": "${local.app_hostname}${count.index+1}",
      "Tags": "${var.resource_environment}"
    }
  EOF

  protected_settings = <<EOF
    { 
      "PATToken": "${var.app_devops["pat"]}" 
    } 
  EOF

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = (var.use_pipeline_environment || var.app_devops["account"] == null) ? 0 : var.app_web_vm_number
  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
resource azurerm_virtual_machine_extension app_web_vm_pipeline_environment {
  name                         = "PipelineAgentCustomScript"
  virtual_machine_id           = azurerm_virtual_machine.app_web_vm[count.index].id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "fileUris": [
                                 "${azurerm_storage_blob.install_agent_script.url}"
      ]
    }
  EOF

  protected_settings           = <<EOF
    { 
      "commandToExecute"       : "powershell.exe -ExecutionPolicy Unrestricted -Command \"./install_agent.ps1 -Environment vdc-${var.tags["environment"]}-app -Organization ${var.app_devops["account"]} -Project ${var.app_devops["team_project"]} -PAT ${var.app_devops["pat"]}\""
    } 
  EOF

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = (var.use_pipeline_environment && var.app_devops["account"] != null) ? var.app_web_vm_number : 0
  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_web_vm_bginfo" {
  name                         = "BGInfo"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.Compute"
  type                         = "BGInfo"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  tags                         = var.tags

  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_web_vm_dependency_monitor" {
  name                         = "DAExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.Monitoring.DependencyAgent"
  type                         = "DependencyAgentWindows"
  type_handler_version         = "9.5"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "workspaceId"            : "${var.diagnostics_workspace_workspace_id}"
    }
  EOF

  protected_settings = <<EOF
    { 
      "workspaceKey"           : "${var.diagnostics_workspace_key}"
    } 
  EOF

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0

  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_web_vm_watcher" {
  name                         = "AzureNetworkWatcherExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.NetworkWatcher"
  type                         = "NetworkWatcherAgentWindows"
  type_handler_version         = "1.4"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_network_watcher && var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  tags                         = var.tags
  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
resource azurerm_virtual_machine_extension app_web_vm_mount_data_disks {
  name                         = "MountDataDisks"
  virtual_machine_id           = azurerm_virtual_machine.app_web_vm[count.index].id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "fileUris": [
                                 "${azurerm_storage_blob.mount_data_disks_script.url}"
      ]
    }
  EOF

  protected_settings           = <<EOF
    { 
      "commandToExecute"       : "powershell.exe -ExecutionPolicy Unrestricted -Command \"./mount_data_disks.ps1\""
    } 
  EOF

  tags                         = var.tags

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor
                                 ]
}
# Does not work with AutoLogon
resource azurerm_virtual_machine_extension app_web_vm_disk_encryption {
  # Trigger new resource every run
  name                         = "DiskEncryption"
  virtual_machine_id           = element(azurerm_virtual_machine.app_web_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.Security"
  type                         = "AzureDiskEncryption"
  type_handler_version         = "2.2"
  auto_upgrade_minor_version   = true

  settings = <<SETTINGS
    {
      "EncryptionOperation"    : "EnableEncryption",
      "KeyVaultURL"            : "${var.key_vault_uri}",
      "KeyVaultResourceId"     : "${var.key_vault_id}",
      "KeyEncryptionKeyURL"    : "${var.key_vault_uri}keys/${azurerm_key_vault_key.disk_encryption_key.name}/${azurerm_key_vault_key.disk_encryption_key.version}",       
      "KekVaultResourceId"     : "${var.key_vault_id}",
      "KeyEncryptionAlgorithm" : "RSA-OAEP",
      "VolumeType"             : "All"
    }
SETTINGS

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  depends_on                   = [
                                  null_resource.start_web_vm,
                                  azurerm_virtual_machine_extension.app_web_vm_monitor,
                                  azurerm_virtual_machine_extension.app_web_vm_mount_data_disks
                                 ]
}

resource "azurerm_lb" "app_db_lb" {
  resource_group_name          = azurerm_resource_group.app_rg.name
  name                         = "${azurerm_resource_group.app_rg.name}-db-lb"
  location                     = azurerm_resource_group.app_rg.location

  sku                          = "Standard" # Zone redundant

  frontend_ip_configuration {
    name                       = "LoadBalancerFrontEnd"
    subnet_id                  = var.data_subnet_id
    private_ip_address         = var.app_db_lb_address
  }

  tags                         = var.tags
}

resource "azurerm_lb_backend_address_pool" "app_db_backend_pool" {
  name                         = "BackendPool1"
  resource_group_name          = azurerm_resource_group.app_rg.name
  loadbalancer_id              = azurerm_lb.app_db_lb.id
}

resource "azurerm_lb_rule" "app_db_lb_rule_tds" {
  resource_group_name          = azurerm_resource_group.app_rg.name
  loadbalancer_id              = azurerm_lb.app_db_lb.id
  name                         = "LBRule"
  protocol                     = "tcp"
  frontend_port                = 1423
  backend_port                 = 1423
  frontend_ip_configuration_name = "LoadBalancerFrontEnd"
  enable_floating_ip           = false
  backend_address_pool_id      = azurerm_lb_backend_address_pool.app_db_backend_pool.id
  idle_timeout_in_minutes      = 5
  probe_id                     = azurerm_lb_probe.app_db_lb_probe_tds.id

  depends_on                   = [azurerm_lb_probe.app_db_lb_probe_tds]
}

resource "azurerm_lb_probe" "app_db_lb_probe_tds" {
  resource_group_name          = azurerm_resource_group.app_rg.name
  loadbalancer_id              = azurerm_lb.app_db_lb.id
  name                         = "TcpProbe"
  protocol                     = "tcp"
  port                         = 1423
  interval_in_seconds          = 5
  number_of_probes             = var.app_db_vm_number
}

resource "azurerm_network_interface" "app_db_if" {
  name                         = "${azurerm_resource_group.app_rg.name}-db-vm${count.index+1}-nic"
  location                     = azurerm_resource_group.app_rg.location
  resource_group_name          = azurerm_resource_group.app_rg.name
  count                        = var.app_db_vm_number

  ip_configuration {
    name                       = "app_db_ipconfig"
    subnet_id                  = var.data_subnet_id
    private_ip_address         = element(var.app_db_vms, count.index)
    private_ip_address_allocation = "Static"
  }

  tags                         = var.tags
}

resource "azurerm_network_interface_backend_address_pool_association" "app_db_if_backend_pool" {
  network_interface_id         = element(azurerm_network_interface.app_db_if.*.id, count.index)
  ip_configuration_name        = element(azurerm_network_interface.app_db_if.*.ip_configuration.0.name, count.index)
  backend_address_pool_id      = azurerm_lb_backend_address_pool.app_db_backend_pool.id
  count                        = var.app_db_vm_number
}

resource "azurerm_virtual_machine" "app_db_vm" {
  name                         = "${azurerm_resource_group.app_rg.name}-db-vm${count.index+1}"
  location                     = azurerm_resource_group.app_rg.location
  resource_group_name          = azurerm_resource_group.app_rg.name
  vm_size                      = var.app_db_vm_size
  network_interface_ids        = [element(azurerm_network_interface.app_db_if.*.id, count.index)]
  # Make zone redundant (# VM's > 2, =< 3)
  zones                        = [(count.index % 3) + 1]
  count                        = var.app_db_vm_number

  storage_image_reference {
    publisher                  = var.app_db_image_publisher
    offer                      = var.app_db_image_offer
    sku                        = var.app_db_image_sku
    version                    = var.app_db_image_version
  }
  # Uncomment this line to delete the OS disk automatically when deleting the VM
  delete_os_disk_on_termination = true

  # Uncomment this line to delete the data disks automatically when deleting the VM
  delete_data_disks_on_termination = true

  storage_os_disk {
    name                       = "${azurerm_resource_group.app_rg.name}-db-vm${count.index+1}-osdisk"
    caching                    = "ReadWrite"
    create_option              = "FromImage"
    managed_disk_type          = "Premium_LRS"
  }

 # Optional data disks
  storage_data_disk {
    name                       = "${azurerm_resource_group.app_rg.name}-db-vm${count.index+1}-datadisk"
    caching                    = "ReadWrite"
    managed_disk_type          = "Premium_LRS"
    create_option              = "Empty"
    lun                        = 0
    disk_size_gb               = "511"
  }

  os_profile {
    computer_name              = "${local.db_hostname}${count.index+1}"
    admin_username             = var.admin_username
    admin_password             = var.admin_password
  }

  os_profile_windows_config {
    provision_vm_agent         = true
    enable_automatic_upgrades  = true
  }

  # Required for AAD Login
  identity {
    type                       = "SystemAssigned"
  }

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )  

  timeouts {
    create                     = var.default_create_timeout
    update                     = var.default_update_timeout
    read                       = var.default_read_timeout
    delete                     = var.default_delete_timeout
  }  

  # Fix for BUG: Error waiting for removal of Backend Address Pool Association for NIC
  depends_on                   = [azurerm_network_interface_backend_address_pool_association.app_db_if_backend_pool]
}

resource null_resource start_db_vm {
  # Always run this
  triggers                     = {
    always_run                 = timestamp()
  }

  provisioner local-exec {
    # Start VM, so we can execute script through SSH
    command                    = "az vm start --ids ${azurerm_virtual_machine.app_db_vm[count.index].id}"
  }

  count                        = var.app_web_vm_number
}

resource azurerm_virtual_machine_extension app_db_vm_monitor {
  name                         = "MMAExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.EnterpriseCloud.Monitoring"
  type                         = "MicrosoftMonitoringAgent"
  type_handler_version         = "1.0"
  auto_upgrade_minor_version   = true
  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }
  settings                     = <<EOF
    {
      "workspaceId"            : "${var.diagnostics_workspace_workspace_id}",
      "azureResourceId"        : "${element(azurerm_virtual_machine.app_db_vm.*.id, count.index)}",
      "stopOnMultipleConnections": "true"
    }
  EOF
  protected_settings = <<EOF
    { 
      "workspaceKey"           : "${var.diagnostics_workspace_key}"
    } 
  EOF

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

# count                        = var.deploy_non_essential_vm_extensions ? var.app_db_vm_number : 0
  count                        = var.app_db_vm_number

  depends_on                   = [null_resource.start_db_vm]
}
resource azurerm_virtual_machine_extension app_db_vm_aadlogin {
  name                         = "AADLoginForWindows"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.ActiveDirectory"
  type                         = "AADLoginForWindows"
  type_handler_version         = "1.0"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_db_vm_number : 0
  tags                         = var.tags
  depends_on                   = [null_resource.start_db_vm]
} 
resource "azurerm_virtual_machine_extension" "app_db_vm_pipeline_deployment_group" {
  name                         = "TeamServicesAgentExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.VisualStudio.Services"
  type                         = "TeamServicesAgent"
  type_handler_version         = "1.26"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "VSTSAccountName": "${var.app_devops["account"]}",        
      "TeamProject": "${var.app_devops["team_project"]}",
      "DeploymentGroup": "${var.app_devops["db_deployment_group"]}",
      "AgentName": "${local.db_hostname}${count.index+1}",
      "Tags": "${var.resource_environment}"
    }
  EOF

  protected_settings = <<EOF
    { 
      "PATToken": "${var.app_devops["pat"]}" 
    } 
  EOF

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  count                        = (var.deploy_non_essential_vm_extensions && !var.use_pipeline_environment && var.app_devops["account"] != null) ? var.app_db_vm_number : 0
  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
resource azurerm_virtual_machine_extension app_db_vm_pipeline_environment {
  name                         = "PipelineAgentCustomScript"
  virtual_machine_id           = azurerm_virtual_machine.app_db_vm[count.index].id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "fileUris": [
                                 "${azurerm_storage_blob.install_agent_script.url}"
      ]
    }
  EOF

  protected_settings           = <<EOF
    { 
      "commandToExecute"       : "powershell.exe -ExecutionPolicy Unrestricted -Command \"./install_agent.ps1 -Environment vdc-${var.tags["environment"]}-app -Organization ${var.app_devops["account"]} -Project ${var.app_devops["team_project"]} -PAT ${var.app_devops["pat"]}\""
    } 
  EOF

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  count                        = (var.deploy_non_essential_vm_extensions && var.use_pipeline_environment && var.app_devops["account"] != null) ? var.app_db_vm_number : 0
  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_db_vm_bginfo" {
  name                         = "BGInfo"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.Compute"
  type                         = "BGInfo"
  type_handler_version         = "2.1"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_non_essential_vm_extensions ? var.app_db_vm_number : 0
  tags                         = var.tags

  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_db_vm_dependency_monitor" {
  name                         = "DAExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.Monitoring.DependencyAgent"
  type                         = "DependencyAgentWindows"
  type_handler_version         = "9.5"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "workspaceId"            : "${var.diagnostics_workspace_workspace_id}"
    }
  EOF

  protected_settings = <<EOF
    { 
      "workspaceKey"           : "${var.diagnostics_workspace_key}"
    } 
  EOF

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  count                        = var.deploy_non_essential_vm_extensions ? var.app_db_vm_number : 0

  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
resource "azurerm_virtual_machine_extension" "app_db_vm_watcher" {
  name                         = "AzureNetworkWatcherExtension"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.NetworkWatcher"
  type                         = "NetworkWatcherAgentWindows"
  type_handler_version         = "1.4"
  auto_upgrade_minor_version   = true

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_network_watcher && var.deploy_non_essential_vm_extensions ? var.app_db_vm_number : 0
  tags                         = var.tags

  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
resource azurerm_virtual_machine_extension app_db_vm_mount_data_disks {
  name                         = "MountDataDisks"
  virtual_machine_id           = azurerm_virtual_machine.app_db_vm[count.index].id
  publisher                    = "Microsoft.Compute"
  type                         = "CustomScriptExtension"
  type_handler_version         = "1.10"
  auto_upgrade_minor_version   = true
  settings                     = <<EOF
    {
      "fileUris": [
                                 "${azurerm_storage_blob.mount_data_disks_script.url}"
      ]
    }
  EOF

  protected_settings           = <<EOF
    { 
      "commandToExecute"       : "powershell.exe -ExecutionPolicy Unrestricted -Command \"./mount_data_disks.ps1\""
    } 
  EOF

  tags                         = var.tags

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor
                                 ]
}
# Does not work with AutoLogon
resource azurerm_virtual_machine_extension app_db_vm_disk_encryption {
  # Trigger new resource every run
  name                         = "DiskEncryption"
  virtual_machine_id           = element(azurerm_virtual_machine.app_db_vm.*.id, count.index)
  publisher                    = "Microsoft.Azure.Security"
  type                         = "AzureDiskEncryption"
  type_handler_version         = "2.2"
  auto_upgrade_minor_version   = true

  settings = <<SETTINGS
    {
      "EncryptionOperation"    : "EnableEncryption",
      "KeyVaultURL"            : "${var.key_vault_uri}",
      "KeyVaultResourceId"     : "${var.key_vault_id}",
      "KeyEncryptionKeyURL"    : "${var.key_vault_uri}keys/${azurerm_key_vault_key.disk_encryption_key.name}/${azurerm_key_vault_key.disk_encryption_key.version}",       
      "KekVaultResourceId"     : "${var.key_vault_id}",
      "KeyEncryptionAlgorithm" : "RSA-OAEP",
      "VolumeType"             : "All"
    }
SETTINGS

  tags                         = merge(
    var.tags,
    map(
      "dummy-dependency",        var.vm_connectivity_dependency
    )
  )

  # Start VM, so we can destroy the extension
  provisioner local-exec {
    command                    = "az vm start --ids ${self.virtual_machine_id}"
    when                       = destroy
  }

  count                        = var.deploy_security_vm_extensions || var.deploy_non_essential_vm_extensions ? var.app_web_vm_number : 0
  depends_on                   = [
                                  null_resource.start_db_vm,
                                  azurerm_virtual_machine_extension.app_db_vm_monitor,
                                  azurerm_virtual_machine_extension.app_db_vm_mount_data_disks
                                 ]
}

resource "azurerm_monitor_diagnostic_setting" "db_lb_logs" {
  name                         = "${azurerm_lb.app_db_lb.name}-logs"
  target_resource_id           = azurerm_lb.app_db_lb.id
  storage_account_id           = var.diagnostics_storage_id
  log_analytics_workspace_id   = var.diagnostics_workspace_resource_id

  log {
    category                   = "LoadBalancerAlertEvent"
    enabled                    = true

    retention_policy {
      enabled                  = false
    }
  }

  log {
    category                   = "LoadBalancerProbeHealthStatus"
    enabled                    = true

    retention_policy {
      enabled                  = false
    }
  }

  metric {
    category                   = "AllMetrics"

    retention_policy {
      enabled                  = false
    }
  }
}