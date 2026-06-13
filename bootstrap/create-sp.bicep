// ── Service Principal creation (deploymentScript) ───────────────────────────
param spName string
param keyVaultName string
param environment string
param location string

resource spScript 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'create-ado-sp-${environment}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    azCliVersion: '2.63.0'
    timeout: 'PT10M'
    retentionInterval: 'PT1H'
    scriptContent: '''
      echo "Creating service principal: $SP_NAME"
      SP_JSON=$(az ad sp create-for-rbac \
        --name "$SP_NAME" \
        --role Contributor \
        --scopes "/subscriptions/$SUBSCRIPTION_ID" \
        --years 2 \
        --output json)

      APP_ID=$(echo "$SP_JSON" | jq -r '.appId')
      PASSWORD=$(echo "$SP_JSON" | jq -r '.password')
      TENANT=$(echo "$SP_JSON" | jq -r '.tenant')

      az keyvault secret set --vault-name "$KEY_VAULT_NAME" \
        --name "ado-sp-appid" --value "$APP_ID" --output none
      az keyvault secret set --vault-name "$KEY_VAULT_NAME" \
        --name "ado-sp-password" --value "$PASSWORD" --output none

      echo "{\"appId\":\"$APP_ID\",\"tenant\":\"$TENANT\",\"subscriptionId\":\"$SUBSCRIPTION_ID\"}" > $AZ_SCRIPTS_OUTPUT_PATH
    '''
    environmentVariables: [
      { name: 'SP_NAME', value: spName }
      { name: 'KEY_VAULT_NAME', value: keyVaultName }
      { name: 'SUBSCRIPTION_ID', value: subscription().subscriptionId }
    ]
  }
}

output identityPrincipalId string = spScript.identity.principalId
output outputs object = spScript.properties.outputs
