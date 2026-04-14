from __future__ import annotations

import logging
import time
from typing import Any, Dict

import requests


CP_HEARTBEAT_URL = "http://10.0.0.20:8000/heartbeat"
HEARTBEAT_INTERVAL_SECONDS = 10
NODE_PAYLOAD: Dict[str, Any] = {
    "node_name": "Node-Storage-01",
    "status": "Online",
    "services": ["SMB", "Backup"],
}


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)
logger = logging.getLogger("node-agent")


def build_payload() -> Dict[str, Any]:
    return dict(NODE_PAYLOAD)


def send_heartbeat() -> None:
    payload = build_payload()
    try:
        response = requests.post(CP_HEARTBEAT_URL, json=payload, timeout=5)
        response.raise_for_status()
        logger.info("Heartbeat sent successfully to %s", CP_HEARTBEAT_URL)
    except requests.RequestException as exc:
        logger.warning("Control Plane unreachable: %s", exc)


def main() -> None:
    logger.info("Node agent started; sending heartbeat every %s seconds", HEARTBEAT_INTERVAL_SECONDS)
    while True: 
        send_heartbeat()
        time.sleep(HEARTBEAT_INTERVAL_SECONDS)


if __name__ == "__main__":
    main()
