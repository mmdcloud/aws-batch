
import requests
from google.cloud import bigquery
import os
from google.cloud import storage
import subprocess

# os.environ['GOOGLE_APPLICATION_CREDENTIALS'] = "./batch-job-sa.json" 

def call_news_api_and_ingest():
    # Call the News API to retrieve data
    api_key = '14411238a52d4395b1f5a73c0ab7dfaa'
    url = 'https://newsapi.org/v2/top-headlines?country=us&apiKey=' + api_key
    response = requests.get(url)
    news_data = response.json()

    # Prepare the data for ingestion into BigQuery
    news_articles = news_data['articles']
    rows_to_insert = []
    for article in news_articles:
        rows_to_insert.append(
            {
                'title': article['title'],
                'description': article['description'],
                'url': article['url']
            }
        )

    # Set up BigQuery client
    project_id = os.environ['PROJECT_ID']
    dataset_id = 'batchnews'
    table_id = 'batchnewstable'
    client = bigquery.Client(project=project_id)

    # Ingest data into BigQuery
    table_ref = client.get_table("batchnews.batchnewstable")

    errors = client.insert_rows(table_ref, rows_to_insert)

    if errors:
        raise Exception(f'Error inserting rows into BigQuery: {errors}')
    else:
        print('Data successfully ingested into BigQuery.')
        
# Calling the function 

call_news_api_and_ingest()