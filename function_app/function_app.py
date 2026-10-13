import azure.functions as func
import logging
import csv
import io

app = func.FunctionApp()


@app.blob_trigger(
    arg_name="myblob",
    path="raw-data/{name}",
    connection="AzureWebJobsStorage"
)
def process_blob(myblob: func.InputStream):
    logging.info(
        "Processing blob: %s (%s bytes)",
        myblob.name,
        myblob.length
    )

    # Read blob content
    content = myblob.read().decode("utf-8")

    # Parse CSV
    reader = csv.DictReader(io.StringIO(content))

    signal_values = []

    for row in reader:
        signal_values.append(float(row["signal"]))

    if not signal_values:
        logging.warning("CSV contains no signal values.")
        return

    # Calculate statistics
    result = {
        "source_file": myblob.name,
        "samples": len(signal_values),
        "mean": sum(signal_values) / len(signal_values),
        "min": min(signal_values),
        "max": max(signal_values),
    }

    logging.info("Processing result: %s", result)