from __future__ import annotations

import argparse
import asyncio
import sqlite3
from pathlib import Path

import asyncpg

TABLES = [
    "otp_codes",
    "workers",
    "claims",
    "zonelock_reports",
    "claim_escalations",
]


def read_rows(sqlite_path: Path, table_name: str) -> tuple[list[str], list[sqlite3.Row]]:
    conn = sqlite3.connect(sqlite_path)
    conn.row_factory = sqlite3.Row
    try:
        cursor = conn.execute(f"SELECT * FROM {table_name}")
        rows = cursor.fetchall()
        columns = [desc[0] for desc in cursor.description or []]
        return columns, rows
    finally:
        conn.close()


async def write_rows(pg: asyncpg.Pool, table_name: str, columns: list[str], rows: list[sqlite3.Row]) -> int:
    if not rows:
        return 0

    col_list = ", ".join(columns)
    placeholders = ", ".join([f"${i}" for i in range(1, len(columns) + 1)])
    query = f"INSERT INTO {table_name} ({col_list}) VALUES ({placeholders})"

    async with pg.acquire() as conn:
        async with conn.transaction():
            for row in rows:
                values = [row[col] for col in columns]
                await conn.execute(query, *values)
    return len(rows)


async def migrate(sqlite_path: Path, supabase_db_url: str) -> None:
    pool = await asyncpg.create_pool(dsn=supabase_db_url, min_size=1, max_size=3)
    try:
        total = 0
        for table in TABLES:
            columns, rows = read_rows(sqlite_path, table)
            count = await write_rows(pool, table, columns, rows)
            total += count
            print(f"migrated {count} rows from {table}")
        print(f"migration complete, total rows={total}")
    finally:
        await pool.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Migrate local SQLite data into Supabase Postgres")
    parser.add_argument("--sqlite", required=True, help="Path to existing SQLite db file")
    parser.add_argument("--supabase-db-url", required=True, help="Supabase Postgres connection URL")
    args = parser.parse_args()

    sqlite_db = Path(args.sqlite).resolve()
    if not sqlite_db.exists():
        raise FileNotFoundError(f"SQLite file not found: {sqlite_db}")

    asyncio.run(migrate(sqlite_db, args.supabase_db_url))
