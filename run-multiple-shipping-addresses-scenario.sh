#!/usr/bin/env bash

#
# executes a scenario with multiple shipping addresses with the commercetools platform
# which is used on https://docs.commercetools.com/tutorial-multiple-shipping-addresses.html
#
# example to call it:
#    export CTP_AUTH_URL="https://auth.commercetools.com"
#    export CTP_API_URL="https://api.commercetools.com"
#    export CTP_PROJECT_KEY="your-project-key"
#    export CTP_CLIENT_ID="your-client-id"
#    export CTP_CLIENT_SECRET="your-client-secret"
#    ./run-multiple-shipping-addresses-scenario.sh

#=======================================================================================================================
echo Configure error handling
#=======================================================================================================================

set -euo pipefail # abort script on first failed command

# variables for colorful echo output
green='\033[0;32m'
red='\033[0;31m'
noColor='\033[0m'

# prints debug information on error events
# example stderr output:
#     http: warning: HTTP 400 Bad Request
#     Error occurred in script './run-multiple-shipping-addresses-scenario.sh' at line: 90.
#     Exit status: 4
function printError() {
  echo -e "${red}Error occurred in script '$0' at line: $1.${noColor}" >&2
  echo -e "${red}Exit status: $2${noColor}" >&2
}

trap 'printError ${LINENO} $?' ERR

#=======================================================================================================================
echo Collect values from environment variables and constant variables
#=======================================================================================================================

authUrl="${CTP_AUTH_URL?Need to set CTP_AUTH_URL}"
apiUrl="${CTP_API_URL?Need to set CTP_API_URL}"
projectKey="${CTP_PROJECT_KEY?Need to set CTP_PROJECT_KEY}"
clientId="${CTP_CLIENT_ID?Need to set CTP_CLIENT_ID}"
clientSecret="${CTP_CLIENT_SECRET?Need to set CTP_CLIENT_SECRET}"
targetFolder=./dynamic
sourceFolder=./static
interestingCartFields='{id,version,lineItems: [.lineItems[] | {id,quantity,shippingDetails}],itemShippingAddresses}'

#=======================================================================================================================
echo Authentication with the Client Credentials Flow
#=======================================================================================================================

# fetches a token with complete read and write access to the project
accessTokenResponse=$(http --check-status -b -a $clientId:$clientSecret --form POST $authUrl/oauth/token \
  grant_type=client_credentials scope=manage_project:$projectKey)
accessToken=$(echo $accessTokenResponse | jq -er .access_token)

#=======================================================================================================================
echo Set standard HTTP headers
#=======================================================================================================================

# fetch the data about the project settings
http --check-status --session=ctp $apiUrl/$projectKey Authorization:"Bearer $accessToken" \
  User-Agent:"httpie-shipping-addresses-tutorial"

#=======================================================================================================================
echo Setup product type, tax category and product
#=======================================================================================================================

productType=$(http --check-status --session-read-only=ctp -b POST $apiUrl/$projectKey/product-types \
  name="productType$RANDOM" description="productType")
productTypeId=$(echo $productType | jq -er .id)

taxCategory=$(http --check-status --session-read-only=ctp -b POST $apiUrl/$projectKey/tax-categories \
  name="taxCat$RANDOM" rates:='[{"name": "de", "amount": 0.19, "includedInPrice": true, "country": "DE"}]')
taxCategoryId=$(echo $taxCategory | jq -er .id )

product_draft=$(cat <<-EOF
{
  "productType": {
    "id": "$productTypeId"
  },
  "name": {"de": "product"},
  "slug": {"de": "product$RANDOM"},
  "taxCategory": {
    "id": "$taxCategoryId",
    "typeId": "tax-category"
  },
  "masterVariant": {
    "prices": [
      {
        "value": {
          "currencyCode": "EUR",
          "centAmount":4200
        }
      }
    ]
  },
  "publish": true
}
EOF
)
productId=$(echo $product_draft | http --check-status --session-read-only=ctp $apiUrl/$projectKey/products | jq -er .id)

#=======================================================================================================================
echo Scenario: Setting the shipping address quantity when the line item is already in the cart
#=======================================================================================================================

mkdir -p $targetFolder #create JSON output folder if not present

# create a cart with a line item
cartDraft=$(cat <<-EOF
{
  "currency": "EUR",
  "country": "DE",
  "lineItems": [
    {
      "productId": "$productId",
      "quantity": 100
    }
  ]
}
EOF
)
cart=$(echo $cartDraft | http --check-status --session-read-only=ctp $apiUrl/$projectKey/carts)
cartId=$(echo $cart | jq -er .id)
cartVersion=$(echo $cart | jq -er .version)
lineItemId=$(echo $cart | jq -er .lineItems[0].id)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/given-cart.json

# add multiple shipping addresses to the cart
cat $sourceFolder/add-itemShippingAddresses.json | jq -e ". + {version: $cartVersion}" \
  > $targetFolder/add-itemShippingAddresses.json
cart=$(cat $targetFolder/add-itemShippingAddresses.json | \
  http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/cartWithItemShippingAddresses.json

# set where the line items should go
cat $sourceFolder/setLineItemShippingDetails.json | jq -e ". + {version: $cartVersion}" | \
  sed "s/lineItemId-value/$lineItemId/g" > $targetFolder/setLineItemShippingDetails.json
cart=$(cat $targetFolder/setLineItemShippingDetails.json | \
  http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/cartWithItemShippingDetailsSet.json

#=======================================================================================================================
echo Scenario: Setting the shipping address quantity when managing a line item
#=======================================================================================================================

# reuse previous cart but remove as prequesition line items entirely
removeLineItem=$(cat <<-EOF
{
  "version": $cartVersion,
  "actions": [
    {
      "action": "removeLineItem",
      "lineItemId": "$lineItemId"
    }
  ]
}
EOF
)
cart=$(echo $removeLineItem | http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
echo "$cart" | jq -e "$interestingCartFields" > $targetFolder/cartReadyForAddLineItem.json

# add line item with shipping details to the empty cart
cat $sourceFolder/addLineItem.json | jq -e '. + {version: '$cartVersion'}' | \
  sed "s/productId-value/$productId/g" > $targetFolder/addLineItem.json
cart=$(cat $targetFolder/addLineItem.json | \
  http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
lineItemId=$(echo $cart | jq -er .lineItems[0].id)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/cartWithAddedLineItem.json

# reduce the line item quantity along with the shipping details quantity
cat $sourceFolder/removeLineItem.json | jq -e '. + {version: '$cartVersion'}' | sed "s/lineItemId-value/$lineItemId/g" \
  > $targetFolder/removeLineItem.json
cart=$(cat $targetFolder/removeLineItem.json | \
  http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/cartWithRemovedLineItem.json

# set absolute quantities
cat $sourceFolder/changeLineItemQuantity.json | jq -e '. + {version: '$cartVersion'}' | \
  sed "s/lineItemId-value/$lineItemId/g" > $targetFolder/changeLineItemQuantity.json
cart=$(cat $targetFolder/changeLineItemQuantity.json | \
  http --check-status --session-read-only=ctp "$apiUrl/$projectKey/carts/$cartId")
cartVersion=$(echo $cart | jq -er .version)
echo $cart | jq -e "$interestingCartFields" > $targetFolder/cartWithChangedLineItemQuantity.json

#=======================================================================================================================
echo -e "${green}Completed scenarios successfully${noColor}"
#=======================================================================================================================