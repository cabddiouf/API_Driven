cat > README.md << 'EOF'
# ATELIER API-DRIVEN INFRASTRUCTURE

L’idée en 30 secondes : **Orchestration de services AWS via API Gateway et Lambda dans un environnement émulé.**  
Cet atelier montre comment concevoir une architecture *API-driven* dans laquelle une requête HTTP déclenche, via **API Gateway** et une **fonction Lambda**, des actions d’infrastructure sur des **instances EC2**, le tout dans un environnement **AWS simulé avec LocalStack** et exécuté dans **GitHub Codespaces**.

L’objectif est de comprendre comment des services cloud serverless peuvent piloter dynamiquement des ressources d’infrastructure, indépendamment de toute console graphique.

---

## 1. Contexte technique

Ce dépôt met en œuvre :

- **GitHub Codespaces** comme environnement de développement distant.
- **LocalStack** pour simuler des services AWS :
  - EC2
  - Lambda
  - API Gateway
  - IAM
- Une **fonction Lambda** en Python (`lambda_function.py`) :
  - reçoit une action `"start"` ou `"stop"`,
  - appelle l’API EC2 de LocalStack.
- Une **API Gateway REST** :
  - ressource `/ec2`,
  - méthode `POST`,
  - intégration proxy vers la Lambda.
- Un **script d’automatisation Bash** (`setup_api_driven.sh`) :
  - (re)crée toute l’infra dans LocalStack,
  - affiche l’URL HTTP finale à appeler.

## 2. Lancer l’environnement (GitHub Codespaces)

1. Aller sur ce dépôt GitHub.
2. Cliquer sur **Code → Codespaces → Create codespace on main**.
3. Attendre que VS Code (dans le navigateur) se lance.

À la racine du repo, les fichiers importants sont :

- `lambda_function.py` : code de la fonction Lambda.
- `setup_api_driven.sh` : script d’automatisation.
- `API_Driven.png` : schéma d’architecture.
- `README.md` : ce document.

## 3. Récupérer l’URL LocalStack (port 4566)

LocalStack est exposé dans le Codespace sur le port **4566**.

GitHub Codespaces fournit automatiquement une URL HTTPS associée à ce port, de la forme :

```text
https://<sous-domaine>-4566.app.github.dev
```
1. Dans le Codespace, ouvrir l’onglet Ports.
2. Repérer la ligne où le Port est 4566.
3. Cliquer sur l’icône globe (Open in browser).
4. Copier l’URL affichée dans la barre d’adresse.
5. Dans le terminal du Codespace, définir :
 ```bash
export AWS_ENDPOINT_URL="https://<sous-domaine>-4566.app.github.dev"
 ```

À chaque nouvelle session Codespaces, le sous-domaine peut changer.
Il faudra donc refaire l’export avec la nouvelle URL du port 4566.

## 4. Automatisation avec `setup_api_driven.sh`

Le script `setup_api_driven.sh` (fourni dans ce dépôt) permet de (re)créer automatiquement tout ce qui est nécessaire dans LocalStack :

- paire de clés EC2,
- instance EC2 simulée,
- rôle IAM pour Lambda,
- fonction Lambda `ec2-controller`,
- API Gateway `api-driven-ec2` avec la ressource `/ec2` et la méthode `POST`,
- intégration Lambda proxy,
- déploiement de l’API en `prod`.

### 4.1. Rendre le script exécutable (une seule fois)

```bash
chmod +x setup_api_driven.sh
```
pour lancer le script : 
 ```bash
./setup_api_driven.sh
 ```
 
Le script exécute les étapes suivantes :

1. Paire de clés EC2

Vérifie si la clé api-driven-key existe dans LocalStack.
Si non, la crée et génère un fichier api-driven-key.pem (droits chmod 400).

2. Instance EC2 simulée

Cherche une instance avec le tag Name=api-driven-instance.
Si aucune n’est trouvée, lance une nouvelle instance EC2 simulée avec ce tag.
Récupère son InstanceId.

3. Rôle IAM pour Lambda

Vérifie si le rôle lambda-ec2-controller-role existe.
Sinon, crée ce rôle avec une trust policy autorisant Lambda à l’assumer.

4. Lambda ec2-controller

Zippe lambda_function.py dans lambda_ec2_controller.zip.
Crée ou met à jour la fonction Lambda ec2-controller avec :
runtime python3.11,
handler lambda_function.lambda_handler,
rôle IAM créé ci-dessus,
variables d’environnement :
AWS_ENDPOINT_URL = l’URL HTTPS de LocalStack (port 4566),
INSTANCE_ID = ID de l’instance EC2 simulée,
AWS_REGION, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY.

5. API Gateway

Crée (ou réutilise) une API REST api-driven-ec2.
Crée (ou réutilise) la ressource /ec2.
Crée (ou réutilise) la méthode POST sur /ec2.
Configure l’intégration de type AWS_PROXY (Lambda proxy) vers la fonction ec2-controller.
Déploie l’API sur le stage prod.

6. Résumé

À la fin, le script affiche un résumé avec :
l’ID de l’instance EC2 simulée,

le nom de la fonction Lambda,

l’ID de l’API Gateway,

l’Endpoint HTTP final de la forme :

https://<sous-domaine>-4566.app.github.dev/restapis/<REST_API_ID>/prod/_user_request_/ec2


## 5. Code de la Lambda `ec2-controller`

La fonction Lambda est définie dans `lambda_function.py`.  
Elle :

1. Lit les variables d’environnement :

   - `AWS_ENDPOINT_URL` : URL de LocalStack (ex. `https://...-4566.app.github.dev`)
   - `INSTANCE_ID` : ID de l’instance EC2 simulée
   - `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`

2. Normalise l’event pour récupérer l’action :

   - appel direct (`aws lambda invoke`) : `event = {"action": "start"}` ou `"stop"`,
   - appel via API Gateway proxy : `event["body"] = '{"action":"start"}'`.

3. Valide l’action (`"start"` ou `"stop"`), sinon renvoie un `statusCode 400`.

4. Crée un client EC2 pointant sur LocalStack :

   ```python
   ec2 = boto3.client(
       "ec2",
       region_name=os.environ.get("AWS_REGION", "us-east-1"),
       endpoint_url=AWS_ENDPOINT_URL,
       aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
       aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
   )

5. Exécute l’action :

start → ec2.start_instances(InstanceIds=[INSTANCE_ID])
stop → ec2.stop_instances(InstanceIds=[INSTANCE_ID])

6. Retourne une réponse JSON comme :

json
{
  "message": "Action 'stop' executed on instance i-xxxxxxxxxxxxxxxxx",
  "rawResponse": "{'StoppingInstances': [...], 'ResponseMetadata': {...}}"
}

## 6. Tester l’API HTTP

### 6.1. Définir l’URL de l’API

Après exécution du script, reprendre l’`Endpoint HTTP` affiché dans le résumé, par exemple :

```bash
API_URL="https://<sous-domaine>-4566.app.github.dev/restapis/<REST_API_ID>/prod/_user_request_/ec2"
```
### 6.2 Démarrer l’instance EC2 simulée
```bash
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{"action":"start"}'
```
### 6.3. Arrêter l’instance EC2 simulée
```bash
curl -X POST "$API_URL" \
  -H "Content-Type: application/json" \
  -d '{"action":"stop"}'
```


## 7. Vérifier l’état de l’instance EC2 dans LocalStack

Pour vérifier que les actions `start` / `stop` ont bien été prises en compte par LocalStack, on peut utiliser l’AWS CLI.

### 7.1. État complet

```bash
aws ec2 describe-instances \
  --endpoint-url "$AWS_ENDPOINT_URL" \
  --instance-ids "<INSTANCE_ID>" \
  --query "Reservations[0].Instances[0].State"
```
exemple de sortie :
{
  "Code": 64,
  "Name": "stopping"
}
### 7.2. Nom de l'état uniquement
aws ec2 describe-instances \
  --endpoint-url "$AWS_ENDPOINT_URL" \
  --instance-ids "<INSTANCE_ID>" \
  --query "Reservations[0].Instances[0].State.Name" \
  --output text

  Sorties possibles :
pending
running
stopping
stopped

Quand le Codespace est fermé puis rouvert :

1. Ouvrir l’onglet **Ports** et récupérer la nouvelle URL du port 4566 :
   ```text
   https://<nouveau-sous-domaine>-4566.app.github.dev
   ```
2. Mettre à jour la variable d’environnement :
    export AWS_ENDPOINT_URL="https://<nouveau-sous-domaine>-4566.app.github.dev"
3. Relancer le script pour (re)configurer l’infrastructure dans
LocalStack : ./setup_api_driven.sh

4. Utiliser le nouvel Endpoint HTTP affiché en fin de script pour tester avec curl.

## 8. Relancer l’atelier dans une nouvelle session Codespaces

Quand le Codespace est fermé puis rouvert :

1. Ouvrir l’onglet **Ports** et récupérer la nouvelle URL du port 4566 :

   ```text
   https://<nouveau-sous-domaine>-4566.app.github.dev
    ```
### 2. Mettre à jour la variable d’environnement :
    export AWS_ENDPOINT_URL="https://<nouveau-sous-domaine>-4566.app.github.dev"

### 3. Relancer le script pour (re)configurer l’infrastructure dans LocalStack :
./setup_api_driven.sh



## 9. Fichiers importants

- `README.md`  
  Guide pas à pas de l’atelier, exécutable entièrement dans GitHub Codespaces.

- `API_Driven.png`  
  Schéma de l’architecture API-driven :
  - appel HTTP `curl` → API Gateway → Lambda → EC2 (via LocalStack).

- `lambda_function.py`  
  Code de la fonction Lambda `ec2-controller` qui :
  - reçoit l’action (`start` / `stop`) depuis l’event,
  - appelle l’API EC2 de LocalStack avec `boto3`.

- `setup_api_driven.sh`  
  Script d’automatisation qui :
  - prépare l’instance EC2 simulée,
  - crée / met à jour la Lambda,
  - crée / configure l’API Gateway REST,
  - affiche l’endpoint HTTP final à utiliser.


