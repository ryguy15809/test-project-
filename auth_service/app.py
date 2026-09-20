"""Auth micro-service — Flask REST API.

Endpoints
---------
POST /register          {username, password}          → {token, account_id, username}
POST /login             {username, password}          → {token, account_id, username}
POST /validate          Header Auth: Bearer <token>   → {valid, account_id, username}
GET  /stats             Header Auth: Bearer <token>   → {wins, losses, matches}
POST /stats/record      Header Auth + {won: bool}     → {wins, losses, matches}
POST /logout            Header Auth: Bearer <token>   → {ok}
"""

from flask import Flask, request, jsonify

import config
import database as db
import auth as auth_

app = Flask(__name__)


# ---------------------------------------------------------------------------
#  helpers
# ---------------------------------------------------------------------------

def _get_token() -> str | None:
    """Extract Bearer token from the Authorization header."""
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[7:]
    return None


def _require_auth() -> dict | None:
    """Return the account dict for a valid token, or send an error response."""
    token = _get_token()
    if not token:
        return None

    payload = auth_.decode_token(token)
    if not payload:
        return None

    # check that the token still exists in the db (hasn't been revoked)
    account = db.get_account_by_token(token)
    if not account:
        return None

    return account


# ---------------------------------------------------------------------------
#  routes
# ---------------------------------------------------------------------------

@app.route("/register", methods=["POST"])
def register():
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "JSON body required"}), 400

    username = (body.get("username") or "").strip()
    password = (body.get("password") or "").strip()

    if len(username) < 2 or len(username) > 32:
        return jsonify({"error": "Username must be 2-32 characters"}), 400
    if len(password) < 4:
        return jsonify({"error": "Password must be at least 4 characters"}), 400

    pwhash = auth_.hash_password(password)
    account_id = db.create_account(username, pwhash)
    if account_id is None:
        return jsonify({"error": "Username already taken"}), 409

    token = auth_.create_token(account_id, username)
    db.save_token(account_id, token)

    return jsonify({
        "token": token,
        "account_id": account_id,
        "username": username,
    }), 201


@app.route("/login", methods=["POST"])
def login():
    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "JSON body required"}), 400

    username = (body.get("username") or "").strip()
    password = (body.get("password") or "").strip()

    account = db.get_account(username)
    if not account or not auth_.check_password(password, account["password"]):
        return jsonify({"error": "Invalid username or password"}), 401

    token = auth_.create_token(account["id"], account["username"])
    db.save_token(account["id"], token)

    return jsonify({
        "token": token,
        "account_id": account["id"],
        "username": account["username"],
    })


@app.route("/validate", methods=["POST"])
def validate():
    account = _require_auth()
    if not account:
        return jsonify({"valid": False}), 401

    return jsonify({
        "valid": True,
        "account_id": account["id"],
        "username": account["username"],
    })


@app.route("/stats", methods=["GET"])
def stats():
    account = _require_auth()
    if not account:
        return jsonify({"error": "Unauthorized"}), 401

    return jsonify(db.get_stats(account["id"]))


@app.route("/stats/record", methods=["POST"])
def record_result():
    account = _require_auth()
    if not account:
        return jsonify({"error": "Unauthorized"}), 401

    body = request.get_json(silent=True) or {}
    won = bool(body.get("won", False))
    db.record_result(account["id"], won)

    return jsonify(db.get_stats(account["id"]))


@app.route("/logout", methods=["POST"])
def logout():
    token = _get_token()
    if token:
        db.delete_token(token)
    return jsonify({"ok": True})


# ---------------------------------------------------------------------------
#  health-check for systemd / load balancers
# ---------------------------------------------------------------------------

@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok"})


# ---------------------------------------------------------------------------
#  entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    db.init()
    app.run(host=config.HOST, port=config.PORT, debug=False)
