import json
import os
import urllib.error
import urllib.request
from typing import Any

from fastapi import FastAPI, HTTPException, Request

app = FastAPI(title="Wazuh AI Bridge")


def required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"{name} is required, example: http://192.168.1.50:11434")
    return value


OLLAMA_BASE_URL = required_env("OLLAMA_BASE_URL").rstrip("/")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama3.1")
OLLAMA_TIMEOUT = float(os.getenv("OLLAMA_TIMEOUT", "60"))


def ollama_chat_url() -> str:
    if OLLAMA_BASE_URL.endswith("/api"):
        return f"{OLLAMA_BASE_URL}/chat"
    return f"{OLLAMA_BASE_URL}/api/chat"


def compact_alert(alert: dict[str, Any]) -> dict[str, Any]:
    rule = alert.get("rule") or {}
    agent = alert.get("agent") or {}
    return {
        "agent_name": agent.get("name"),
        "rule_id": rule.get("id"),
        "rule_level": rule.get("level"),
        "description": rule.get("description"),
        "timestamp": alert.get("timestamp"),
        "full_log": str(alert.get("full_log", ""))[:4000],
    }


def build_prompt(alert: dict[str, Any]) -> str:
    return (
        "Analyze this Wazuh security alert for a security analyst. "
        "Explain what likely happened, how serious it is, and what to do next. "
        "Do not invent facts that are not in the alert.\n\n"
        f"{json.dumps(compact_alert(alert), indent=2)}"
    )


def ask_ollama(prompt: str) -> str:
    payload = {
        "model": OLLAMA_MODEL,
        "stream": False,
        "messages": [
            {
                "role": "system",
                "content": "You explain Wazuh alerts in concise natural language.",
            },
            {"role": "user", "content": prompt},
        ],
    }
    request = urllib.request.Request(
        ollama_chat_url(),
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=OLLAMA_TIMEOUT) as response:
            body = json.loads(response.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=502, detail=f"Ollama request failed: {exc}") from exc

    content = ((body.get("message") or {}).get("content") or "").strip()
    if not content:
        raise HTTPException(status_code=502, detail="Ollama returned an empty response")
    return content


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "model": OLLAMA_MODEL}


@app.post("/receive-alert")
async def receive_alert(request: Request) -> dict[str, Any]:
    alert = await request.json()
    if not isinstance(alert, dict):
        raise HTTPException(status_code=400, detail="Expected a JSON object")

    metadata = compact_alert(alert)
    return {
        "status": "ok",
        "model": OLLAMA_MODEL,
        "alert": metadata,
        "analysis": ask_ollama(build_prompt(alert)),
    }
