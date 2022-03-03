"""Command utilities for managing pgstac."""
# import asyncio
# import time
from typing import Optional

# import asyncpg
# import typer
import fire
from .db import PgstacDB
from .migrate import Migrate
import logging


class PgstacCLI:
    def __init__(self, dsn: Optional[str] = "", debug: bool = False):
        self.dsn = dsn
        self._db = PgstacDB(dsn=dsn, debug=debug)
        self.initial_version = "0.1.9"
        if debug:
            logging.basicConfig(level=logging.DEBUG)

    @property
    def version(self):
        """Get PGStac version installed on database."""
        return self._db.version

    @property
    def pg_version(self):
        """Get PostgreSQL server version installed on database."""
        return self._db.pg_version

    def pgready(self):
        """Wait for a pgstac database to accept connections."""
        return self._db.wait()

    def search(self, query: str):
        return self._db.search(query)

    def migrate(self, toversion: Optional[str] = None):
        migrator = Migrate(self._db)
        return migrator.run_migration(toversion=toversion)


def cli():
    fire.Fire(PgstacCLI)


if __name__ == "__main__":
    fire.Fire(PgstacCLI)

# from .migrate import run_migration, get_version_dsn, get_initial_version
# from .load import loadopt, tables, load_ndjson

# app = typer.Typer()


# @app.command()
# def version(dsn: Optional[str] = None) -> None:
#     """Get version from a pgstac database."""
#     version = asyncio.run(get_version_dsn(dsn))
#     typer.echo(f"{version}")


# @app.command()
# def initversion() -> None:
#     """Get initial version."""
#     typer.echo(get_initial_version())


# @app.command()
# def migrate(dsn: Optional[str] = None, toversion: Optional[str] = None) -> None:
#     """Migrate a pgstac database."""
#     version = asyncio.run(run_migration(dsn, toversion))
#     typer.echo(f"pgstac version {version}")


# @app.command()
# def load(
#     table: tables,
#     file: str,
#     dsn: str = None,
#     method: loadopt = typer.Option("insert", prompt="How to deal conflicting ids"),
# ) -> None:
#     """Load STAC data into a pgstac database."""
#     typer.echo(asyncio.run(load_ndjson(file=file, table=table, dsn=dsn, method=method)))


# @app.command()
# def pgready(dsn: Optional[str] = None) -> None:
#     """Wait for a pgstac database to accept connections."""

#     async def wait_on_connection() -> bool:
#         cnt = 0

#         print("Waiting for pgstac to come online...", end="", flush=True)
#         while True:
#             if cnt > 150:
#                 raise Exception("Unable to connect to database")
#             try:
#                 print(".", end="", flush=True)
#                 conn = await asyncpg.connect(dsn=dsn)
#                 await conn.execute("SELECT 1")
#                 await conn.close()
#                 print("success!")
#                 return True
#             except Exception:
#                 time.sleep(0.1)
#                 cnt += 1

#     asyncio.run(wait_on_connection())


# if __name__ == "__main__":
#     app()
