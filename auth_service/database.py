"""SQLite database layer — schema, account CRUD, stats."""

import sqlite3
import config


def _connect() -> sqlite3.Connection:
    conn = sqlite3.connect(config.DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


# ---------------------------------------------------------------------------
#  one-time init
# ---------------------------------------------------------------------------

def init() -> None:
    """Create tables if they don't already exist."""
    with _connect() as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS accounts (
                id          INTEGER PRIMARY KEY AUTOINCREMENT,
                username    TEXT    NOT NULL UNIQUE COLLATE NOCASE,
                password    TEXT    NOT NULL,
                created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS tokens (
                token       TEXT    PRIMARY KEY,
                account_id  INTEGER NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
                created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
            );

            CREATE TABLE IF NOT EXISTS stats (
                account_id  INTEGER PRIMARY KEY REFERENCES accounts(id) ON DELETE CASCADE,
                wins        INTEGER NOT NULL DEFAULT 0,
                losses      INTEGER NOT NULL DEFAULT 0,
                matches     INTEGER NOT NULL DEFAULT 0
            );

            CREATE INDEX IF NOT EXISTS idx_tokens_account ON tokens(account_id);
        """)


# ---------------------------------------------------------------------------
#  accounts
# ---------------------------------------------------------------------------

def create_account(username: str, password_hash: str) -> int | None:
    """Insert a new account.  Returns the new account id, or *None* if the
    username is already taken."""
    try:
        with _connect() as db:
            cur = db.execute(
                "INSERT INTO accounts (username, password) VALUES (?, ?)",
                (username, password_hash),
            )
            account_id = cur.lastrowid
            # every account starts with a zeroed stats row
            db.execute("INSERT INTO stats (account_id) VALUES (?)", (account_id,))
            return account_id
    except sqlite3.IntegrityError:
        return None


def get_account(username: str) -> dict | None:
    """Return account row (id, username, password) or None."""
    with _connect() as db:
        row = db.execute(
            "SELECT id, username, password FROM accounts WHERE username = ?",
            (username,),
        ).fetchone()
    return dict(row) if row else None


# ---------------------------------------------------------------------------
#  tokens
# ---------------------------------------------------------------------------

def save_token(account_id: int, token: str) -> None:
    with _connect() as db:
        db.execute(
            "INSERT INTO tokens (token, account_id) VALUES (?, ?)",
            (token, account_id),
        )


def get_account_by_token(token: str) -> dict | None:
    """Return account row (id, username) for a valid token, or None."""
    with _connect() as db:
        row = db.execute(
            """SELECT a.id, a.username
               FROM tokens t
               JOIN accounts a ON a.id = t.account_id
               WHERE t.token = ?""",
            (token,),
        ).fetchone()
    return dict(row) if row else None


def delete_token(token: str) -> None:
    with _connect() as db:
        db.execute("DELETE FROM tokens WHERE token = ?", (token,))


# ---------------------------------------------------------------------------
#  stats
# ---------------------------------------------------------------------------

def get_stats(account_id: int) -> dict:
    with _connect() as db:
        row = db.execute(
            "SELECT wins, losses, matches FROM stats WHERE account_id = ?",
            (account_id,),
        ).fetchone()
    return dict(row) if row else {"wins": 0, "losses": 0, "matches": 0}


def record_result(account_id: int, won: bool) -> None:
    with _connect() as db:
        db.execute(
            """UPDATE stats
               SET wins   = wins   + ?,
                   losses = losses + ?,
                   matches = matches + 1
               WHERE account_id = ?""",
            (1 if won else 0, 0 if won else 1, account_id),
        )
