"""Password hashing (bcrypt) and JWT token handling."""

import uuid
from datetime import datetime, timezone, timedelta

import bcrypt
import jwt

import config


# ---------------------------------------------------------------------------
#  passwords
# ---------------------------------------------------------------------------

def hash_password(password: str) -> str:
    return bcrypt.hashpw(
        password.encode("utf-8"), bcrypt.gensalt(rounds=config.BCRYPT_ROUNDS)
    ).decode("utf-8")


def check_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode("utf-8"), hashed.encode("utf-8"))


# ---------------------------------------------------------------------------
#  tokens  (JWT with per-device jti for revocation)
# ---------------------------------------------------------------------------

def create_token(account_id: int, username: str) -> str:
    """Issue a new JWT. The *jti* claim lets us revoke individual tokens."""
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(account_id),       # subject — who this token belongs to
        "usr": username,              # shortcut so callers don't need a second lookup
        "jti": uuid.uuid4().hex,      # unique id — stored in DB for revocation
        "iat": now,
        "exp": now + timedelta(days=config.TOKEN_EXPIRY_DAYS),
    }
    return jwt.encode(payload, config.JWT_SECRET, algorithm=config.JWT_ALGORITHM)


def decode_token(token: str) -> dict | None:
    """Return the payload dict if the token is valid and unexpired, else None."""
    try:
        return jwt.decode(
            token, config.JWT_SECRET, algorithms=[config.JWT_ALGORITHM]
        )
    except (jwt.ExpiredSignatureError, jwt.InvalidTokenError):
        return None
