"""Shared configuration — single source of truth for all settings."""

import os

# ----- database -----
DB_PATH: str = os.environ.get("AUTH_DB_PATH", "auth.db")

# ----- token -----
JWT_SECRET: str = os.environ.get("AUTH_JWT_SECRET", "change-me-in-production")
JWT_ALGORITHM: str = "HS256"
TOKEN_EXPIRY_DAYS: int = 90  # tokens last 90 days before requiring re-login

# ----- server -----
HOST: str = os.environ.get("AUTH_HOST", "0.0.0.0")
PORT: int = int(os.environ.get("AUTH_PORT", "8090"))

# ----- bcrypt -----
BCRYPT_ROUNDS: int = 12  # cost factor — 12 is a good balance for small servers
