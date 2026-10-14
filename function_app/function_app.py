import azure.functions as func
import logging
import csv
import io
import os

from azure.cosmos import CosmosClient
from azure.identity import ManagedIdentityCredential

app = func.FunctionApp()

credential = ManagedIdentityCredential()

cosmos_client = CosmosClient(
    os.environ["COSMOS_ENDPOINT"],
    credential=credential
)

database = cosmos_client.get_database_client("pipeline-db")
container = database.get_container_client("results")


@app.blob_trigger(
    arg_name="myblob",
    path="raw-data/{name}",
    connection="AzureWebJobsStorage",
    source="EventGrid"
)
def process_blob(myblob: func.InputStream):
    logging.info(
        "Processing blob: %s (%s bytes)",
        myblob.name,
        myblob.length
    )

    try:
        content = myblob.read().decode("utf-8")
        reader = csv.DictReader(io.StringIO(content))

        if not reader.fieldnames or "signal" not in reader.fieldnames:
            raise ValueError("CSV does not contain a 'signal' column.")

        signal_values = []

        for row in reader:
            signal_values.append(float(row["signal"]))

        if not signal_values:
            raise ValueError("CSV contains no signal values.")

        source_file = myblob.name.rsplit("/", 1)[-1]

        result = {
            "id": source_file,
            "source_file": source_file,
            "samples": len(signal_values),
            "mean": sum(signal_values) / len(signal_values),
            "min": min(signal_values),
            "max": max(signal_values),
        }

        container.upsert_item(result)

        logging.info(
            "Successfully processed %s and stored result in Cosmos DB.",
            source_file
        )

    except (ValueError, UnicodeDecodeError) as exc:
        logging.error(
            "Invalid input file %s: %s",
            myblob.name,
            exc
        )
        raise

    except Exception:
        logging.exception(
            "Unexpected error while processing %s.",
            myblob.name
        )
        raise