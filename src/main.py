import requests
import psycopg2
from psycopg2 import sql
from datetime import datetime
import os
from typing import List, Dict

def fetch_newsapi_data(api_key: str, query: str = "technology", page_size: int = 100) -> List[Dict]:
    """Fetch news articles from NewsAPI."""
    url = "https://newsapi.org/v2/"+str+"?country=us&apiKey=" + api_key
    params = {
        "q": query,
        "pageSize": page_size,
        "apiKey": api_key,
        "sortBy": "publishedAt",
        "language": "en"
    }
    
    try:
        response = requests.get(url, params=params)
        response.raise_for_status()  # Raise HTTP errors
        data = response.json()
        
        if data["status"] != "ok":
            raise ValueError(f"NewsAPI error: {data.get('message', 'Unknown error')}")
        
        return data.get("articles", [])
    
    except requests.exceptions.RequestException as e:
        print(f"Failed to fetch NewsAPI data: {e}")
        return []

def write_news_to_redshift(articles: List[Dict], redshift_config: Dict):
    """Write NewsAPI data to Redshift."""
    if not articles:
        print("No articles to write.")
        return
    
    # Establish Redshift connection
    try:
        conn = psycopg2.connect(
            dbname=redshift_config["dbname"],
            user=redshift_config["user"],
            password=redshift_config["password"],
            host=redshift_config["host"],
            port=redshift_config["port"]
        )
        cursor = conn.cursor()
        
        # Create table if not exists
        create_table_query = """
        CREATE TABLE IF NOT EXISTS news_articles (
            id VARCHAR(255) PRIMARY KEY,
            title TEXT,
            author VARCHAR(255),
            source_name VARCHAR(255),
            published_at TIMESTAMP,
            url TEXT,
            content TEXT,
            description TEXT,
            inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );
        """
        cursor.execute(create_table_query)
        
        # Batch insert articles
        insert_query = """
        INSERT INTO news_articles (id, title, author, source_name, published_at, url, content, description)
        VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        ON CONFLICT (id) DO NOTHING;
        """
        
        records = []
        for article in articles:
            article_id = hash(article["url"]) & 0xFFFFFFFF
            published_at = datetime.strptime(article["publishedAt"], "%Y-%m-%dT%H:%M:%SZ")
            
            records.append((
                str(article_id),
                article["title"],
                article.get("author"),
                article["source"]["name"],
                published_at,
                article["url"],
                article.get("content"),
                article.get("description")
            ))
        
        cursor.executemany(insert_query, records)
        conn.commit()
        print(f"Successfully inserted {len(records)} articles.")
        
    except Exception as e:
        print(f"Redshift error: {e}")
        conn.rollback()
    finally:
        if conn:
            conn.close()

# Example Usage
if __name__ == "__main__":
    NEWSAPI_KEY = "14411238a52d4395b1f5a73c0ab7dfaa"
    REDSHIFT_CONFIG = {
        "dbname": os.getenv("REDSHIFT_DBNAME"),
        "user": os.getenv("REDSHIFT_USER"),
        "password": os.getenv("REDSHIFT_PASSWORD"),
        "host": os.getenv("REDSHIFT_HOST"),
        "port": os.getenv("REDSHIFT_PORT")
    }
    
    # Fetch and write data
    articles = fetch_newsapi_data(NEWSAPI_KEY, query="AI")
    write_news_to_redshift(articles, REDSHIFT_CONFIG)