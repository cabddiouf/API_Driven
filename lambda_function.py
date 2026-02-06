import os
import json
import boto3

AWS_ENDPOINT_URL = os.environ.get("AWS_ENDPOINT_URL")
INSTANCE_ID = os.environ.get("INSTANCE_ID")


def lambda_handler(event, context):
    """
    Lambda de contrôle d'une instance EC2 sur LocalStack.
    - En appel direct (aws lambda invoke) : event = {"action": "start"|"stop"}
    - Via API Gateway proxy : event["body"] = '{"action":"start"}'
    """

    if not AWS_ENDPOINT_URL:
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Missing AWS_ENDPOINT_URL env var"})
        }

    if not INSTANCE_ID:
        return {
            "statusCode": 500,
            "body": json.dumps({"error": "Missing INSTANCE_ID env var"})
        }

    # Normaliser l'event pour récupérer l'action
    action = None

    # Cas appel direct (aws lambda invoke)
    if isinstance(event, dict) and "action" in event:
        action = event.get("action")

    # Cas API Gateway proxy : body est une chaîne JSON
    elif isinstance(event, dict) and "body" in event:
        try:
            body = event["body"]
            if isinstance(body, str):
                body = json.loads(body)
            action = body.get("action")
        except Exception:
            action = None

    if action not in ("start", "stop"):
        return {
            "statusCode": 400,
            "body": json.dumps({"error": "Invalid or missing 'action'. Use 'start' or 'stop'."})
        }

    ec2 = boto3.client(
        "ec2",
        region_name=os.environ.get("AWS_REGION", "us-east-1"),
        endpoint_url=AWS_ENDPOINT_URL,
        aws_access_key_id=os.environ.get("AWS_ACCESS_KEY_ID", "test"),
        aws_secret_access_key=os.environ.get("AWS_SECRET_ACCESS_KEY", "test"),
    )

    try:
        if action == "start":
            response = ec2.start_instances(InstanceIds=[INSTANCE_ID])
        else:  # action == "stop"
            response = ec2.stop_instances(InstanceIds=[INSTANCE_ID])

        return {
            "statusCode": 200,
            "body": json.dumps({
                "message": f"Action '{action}' executed on instance {INSTANCE_ID}",
                "rawResponse": str(response)
            })
        }

    except Exception as e:
        return {
            "statusCode": 500,
            "body": json.dumps({"error": str(e)})
        }
