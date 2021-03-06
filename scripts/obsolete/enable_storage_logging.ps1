#!/usr/bin/env pwsh
<# 
.SYNOPSIS 
    Enables storage diagnostics
 
.DESCRIPTION 
    This is a temporary workaround until storage logging can be enabled from within Terraform
#> 
param (    
    [parameter(Mandatory=$true)][string]$StorageAccountName,
    [parameter(Mandatory=$true)][string]$ResourceGroupName

)

# Enable logging on storage account
Write-Host "Enabling blob logging for storage account ${StorageAccountName}..."
$storageKey = $(az storage account keys list -n $StorageAccountName --query "[0].value" -o tsv)
az storage logging update --account-name $StorageAccountName --account-key $storageKey --log rwd --retention 90 --services b
