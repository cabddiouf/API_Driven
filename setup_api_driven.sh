#!/usr/bin/env bash
set -euo pipefail

###############################################
# Configuration
###############################################

# URL LocalStack exposée par GitHub Codespaces
AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:?AWS_ENDPOINT_URL non défini. Merci de définir la variable d'environnement avant d'exécuter ce script.}"

AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Nom des ressources
EC2_KEY_NAME="api-driven-key"
LAMBDA_ROLE_NAME="lambda-ec2-controller-role"
LAMBDA_FUNCTION_NAME="ec2-controller"
REST_API_NAME="api-driven-ec2"

###############################################
# Helpers
###############################################

echo_title() {
  echo
  echo "========================================"
  echo "$1"
  echo "========================================"
}

aws_cmd() {
  aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"
}

###############################################
# 1) EC2 : clé + instance
###############################################

echo_title "1) Vérification / création de la paire de clés EC2"

if ! aws_cmd ec2 describe-key-pairs --key-names "$EC2_KEY_NAME" >/dev/null 2>&1; then
  echo "-> Clé $EC2_KEY_NAME absente, création..."
  aws_cmd ec2 create-key-pair --key-name "$EC2_KEY_NAME" \
    --query "KeyMaterial" \
    --output text > "${EC2_KEY_NAME}.pem"
  chmod 400 "${EC2_KEY_NAME}.pem"
  echo "-> Clé créée et sauvegardée dans ${EC2_KEY_NAME}.pem"
else
  echo "-> Clé $EC2_KEY_NAME déjà existante, on la réutilise."
fi

echo_title "2) Vérification / création de l'instance EC2"

INSTANCE_ID=$(aws_cmd ec2 describe-instances \
  --filters "Name=tag:Name,Values=api-driven-instance" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null || echo "None")

if [[ "$INSTANCE_ID" == "None" || "$INSTANCE_ID" == "None
" ]]; then
  echo "-> Aucune instance avec le tag Name=api-driven-instance, création..."
  INSTANCE_ID=$(aws_cmd ec2 run-instances \
    --image-id "ami-12345678" \
    --instance-type "t2.micro" \
    --key-name "$EC2_KEY_NAME" \
    --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=api-driven-instance}]' \
    --query "Instances[0].InstanceId" \
    --output text)

  echo "-> Instance créée : $INSTANCE_ID"
else
  echo "-> Instance déjà existante : $INSTANCE_ID"
fi

###############################################
# 2) IAM : rôle pour Lambda
###############################################

echo_title "3) Vérification / création du rôle IAM pour Lambda"

TRUST_POLICY_FILE="trust-policy.json"
if [[ ! -f "$TRUST_POLICY_FILE" ]]; then
  cat > "$TRUST_POLICY_FILE" << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
  echo "-> $TRUST_POLICY_FILE créé."
fi

if ! aws_cmd iam get-role --role-name "$LAMBDA_ROLE_NAME" >/dev/null 2>&1; then
  echo "-> Rôle $LAMBDA_ROLE_NAME absent, création..."
  aws_cmd iam create-role \
    --role-name "$LAMBDA_ROLE_NAME" \
    --assume-role-policy-document "file://$TRUST_POLICY_FILE" >/dev/null
else
  echo "-> Rôle $LAMBDA_ROLE_NAME déjà existant."
fi

ROLE_ARN=$(aws_cmd iam get-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --query "Role.Arn" \
  --output text)

echo "-> ROLE_ARN: $ROLE_ARN"

###############################################
# 3) Lambda : zip + create/update
###############################################

echo_title "4) Packaging de la Lambda"

if [[ ! -f "lambda_function.py" ]]; then
  echo "ERREUR : lambda_function.py est introuvable à la racine du repo."
  exit 1
fi

zip -q lambda_ec2_controller.zip lambda_function.py
echo "-> lambda_ec2_controller.zip généré."

echo_title "5) Création / mise à jour de la fonction Lambda"

ENV_VARS="Variables={AWS_ENDPOINT_URL=$AWS_ENDPOINT_URL,INSTANCE_ID=$INSTANCE_ID,AWS_REGION=$AWS_REGION,AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID,AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY}"

if ! aws_cmd lambda get-function --function-name "$LAMBDA_FUNCTION_NAME" >/devnull 2>&1; then
  echo "-> Fonction $LAMBDA_FUNCTION_NAME absente, création..."
  aws_cmd lambda create-function \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --runtime python3.11 \
    --role "$ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file fileb://lambda_ec2_controller.zip \
    --environment "$ENV_VARS" >/dev/null
else
  echo "-> Fonction $LAMBDA_FUNCTION_NAME déjà existante, mise à jour du code..."
  aws_cmd lambda update-function-code \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --zip-file fileb://lambda_ec2_controller.zip >/dev/null

  echo "-> Mise à jour de la configuration (variables d'env)..."
  aws_cmd lambda update-function-configuration \
    --function-name "$LAMBDA_FUNCTION_NAME" \
    --environment "$ENV_VARS" >/dev/null
fi

LAMBDA_ARN="arn:aws:lambda:${AWS_REGION}:000000000000:function:${LAMBDA_FUNCTION_NAME}"
echo "-> LAMBDA_ARN: $LAMBDA_ARN"

###############################################
# 4) API Gateway : REST API + ressource + méthode + intégration
###############################################

echo_title "6) Configuration d'API Gateway"

EXISTING_REST_API_ID=$(aws_cmd apigateway get-rest-apis \
  --query "items[?name=='${REST_API_NAME}'].id | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "$EXISTING_REST_API_ID" == "None" || "$EXISTING_REST_API_ID" == "None
" ]]; then
  echo "-> Aucune API nommée ${REST_API_NAME}, création..."
  REST_API_ID=$(aws_cmd apigateway create-rest-api \
    --name "$REST_API_NAME" \
    --query "id" \
    --output text)
else
  echo "-> API ${REST_API_NAME} déjà existante (id=${EXISTING_REST_API_ID}), réutilisation."
  REST_API_ID="$EXISTING_REST_API_ID"
fi

echo "-> REST_API_ID: $REST_API_ID"

PARENT_ID=$(aws_cmd apigateway get-resources \
  --rest-api-id "$REST_API_ID" \
  --query "items[0].id" \
  --output text)

echo "-> PARENT_ID: $PARENT_ID"

RESOURCE_ID=$(aws_cmd apigateway get-resources \
  --rest-api-id "$REST_API_ID" \
  --query "items[?path=='/ec2'].id | [0]" \
  --output text 2>/dev/null || echo "None")

if [[ "$RESOURCE_ID" == "None" || "$RESOURCE_ID" == "None
" ]]; then
  echo "-> Ressource /ec2 absente, création..."
  RESOURCE_ID=$(aws_cmd apigateway create-resource \
    --rest-api-id "$REST_API_ID" \
    --parent-id "$PARENT_ID" \
    --path-part ec2 \
    --query "id" \
    --output text)
else
  echo "-> Ressource /ec2 déjà existante (id=${RESOURCE_ID}), réutilisation."
fi

echo "-> RESOURCE_ID: $RESOURCE_ID"

if ! aws_cmd apigateway get-method \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST >/dev/null 2>&1; then
  echo "-> Méthode POST absente, création..."
  aws_cmd apigateway put-method \
    --rest-api-id "$REST_API_ID" \
    --resource-id "$RESOURCE_ID" \
    --http-method POST \
    --authorization-type "NONE" >/dev/null
else
  echo "-> Méthode POST déjà existante."
fi

aws_cmd apigateway put-integration \
  --rest-api-id "$REST_API_ID" \
  --resource-id "$RESOURCE_ID" \
  --http-method POST \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri "arn:aws:apigateway:${AWS_REGION}:lambda:path/2015-03-31/functions/${LAMBDA_ARN}/invocations" >/dev/null

echo "-> Intégration Lambda configurée."

aws_cmd apigateway create-deployment \
  --rest-api-id "$REST_API_ID" \
  --stage-name prod >/dev/null || true

###############################################
# 5) Résumé
###############################################

echo_title "7) Résumé"

API_URL="${AWS_ENDPOINT_URL}/restapis/${REST_API_ID}/prod/_user_request_/ec2"

cat << EOF
Instance EC2 simulée : $INSTANCE_ID
Fonction Lambda     : $LAMBDA_FUNCTION_NAME
API Gateway ID      : $REST_API_ID
Endpoint HTTP       : $API_URL

Exemples d'appel :

# Démarrer l'instance
curl -X POST "$API_URL" \\
  -H "Content-Type: application/json" \\
  -d '{"action":"start"}'

# Arrêter l'instance
curl -X POST "$API_URL" \\
  -H "Content-Type: application/json" \\
  -d '{"action":"stop"}'
EOF
