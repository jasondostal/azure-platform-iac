using '../main.bicep'

param environment = 'dev'
param location = 'eastus'
param tenantId = ''       // Your Entra tenant GUID
param platformName = 'platform'
param createServicePrincipal = true
