import json


def handler(event, context):
    for record in event.get("Records", []):
        key = record["s3"]["object"]["key"]
        print(f"Image received: {key}")
    return {"statusCode": 200}
