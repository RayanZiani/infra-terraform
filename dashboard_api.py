from __future__ import annotations
import os
from datetime import datetime, timezone
from html import escape
from threading import Lock
from typing import Dict, List, Optional
from fastapi import FastAPI, HTTPException
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
import uvicorn
import psycopg2

class HeartbeatPayload(BaseModel):
    node_name: str = Field(..., min_length=1)
    status: str = Field(..., min_length=1)
    uptime: Optional[str] = None
    services: List[str] = Field(default_factory=list)

app = FastAPI(title="SecureNet Dashboard API")
_state_lock = Lock()
_node_state: Dict[str, Dict[str, object]] = {}

def get_nfs_files():
    path = "/mnt/nfs_client"
    try:
        if os.path.exists(path):
            return os.listdir(path)
        return ["Dossier NFS non monté"]
    except Exception as e:
        return [f"Erreur : {str(e)}"]

def get_db_count():
    try:
        conn = psycopg2.connect(dbname="securenet_prod", user="postgres", host="localhost")
        cur = conn.cursor()
        cur.execute("SELECT COUNT(*) FROM equipements;")
        count = cur.fetchone()[0]
        cur.close()
        conn.close()
        return count
    except:
        return "N/A"

@app.get("/", response_class=HTMLResponse)
def dashboard() -> str:
    with _state_lock:
        nodes = list(_node_state.values())

    rows = []
    for node in sorted(nodes, key=lambda item: str(item["node_name"])):
        services = node.get("services") or []
        services_html = ", ".join(escape(str(service)) for service in services) if services else "-"
        rows.append(f"<tr><td>{escape(str(node.get('node_name', '-')))}</td><td>{escape(str(node.get('status', '-')))}</td><td>{escape(str(node.get('uptime', 'N/A')))}</td><td>{services_html}</td><td>{escape(str(node.get('last_seen', '-')))}</td></tr>")

    # Infos NFS et BDD
    nfs_files = get_nfs_files()
    files_html = "".join([f"<li>{escape(f)}</li>" for f in nfs_files])
    db_count = get_db_count()

    html = f"""
    <!DOCTYPE html>
    <html lang="fr">
    <head>
        <meta charset="utf-8" />
        <title>SecureNet Dashboard Pro</title>
        <style>
            :root {{ --bg: #f5f7fb; --panel: #ffffff; --text: #0f172a; --accent: #0f766e; --border: #dbe3ee; }}
            body {{ font-family: sans-serif; background: var(--bg); color: var(--text); margin: 20px; }}
            .container {{ max-width: 1000px; margin: 0 auto; }}
            .panel {{ background: var(--panel); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.05); }}
            h1, h2 {{ color: var(--accent); margin-top: 0; }}
            table {{ width: 100%; border-collapse: collapse; }}
            th, td {{ padding: 12px; text-align: left; border-bottom: 1px solid var(--border); }}
            .stats-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }}
            ul {{ padding-left: 20px; }}
        </style>
    </head>
    <body>
        <div class="container">
            <div class="panel">
                <h1>🛡️ SecureNet Infrastructure</h1>
                <p>Statut global du réseau privé</p>
            </div>

            <div class="panel">
                <h2>🖥️ Nœuds Actifs</h2>
                <table>
                    <thead><tr><th>Node</th><th>Status</th><th>Uptime</th><th>Services</th><th>Last Seen</th></tr></thead>
                    <tbody>{"".join(rows) if rows else "<tr><td colspan='5'>En attente...</td></tr>"}</tbody>
                </table>
            </div>

            <div class="stats-grid">
                <div class="panel">
                    <h2>📁 Fichiers sur le NFS (Node-01)</h2>
                    <ul>{files_html}</ul>
                </div>
                <div class="panel">
                    <h2>📊 Base de Données (Postgres)</h2>
                    <p style="font-size: 2rem; font-weight: bold; color: var(--accent);">{db_count} <span style="font-size: 1rem; color: #64748b;">équipements enregistrés</span></p>
                </div>
            </div>
        </div>
    </body>
    </html>
    """
    return html

@app.post("/heartbeat")
def heartbeat(payload: HeartbeatPayload) -> Dict[str, str]:
    received_at = datetime.now(timezone.utc).strftime("%H:%M:%S")
    node_data = {
        "node_name": str(payload.node_name),
        "status": str(payload.status),
        "uptime": str(payload.uptime or "N/A"),
        "services": list(payload.services),
        "last_seen": received_at,
    }
    with _state_lock:
        _node_state[payload.node_name] = node_data
    
    return {"message": "OK"}