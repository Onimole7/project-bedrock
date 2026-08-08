def handler(event, context):
    for record in event["Records"]:
        key = record["s3"]["object"]["key"]
        print(f"Image received: {key}")
