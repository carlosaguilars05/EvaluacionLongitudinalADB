#!/usr/bin/env python3
"""
PreToolUse Hook del Harness — Bloquea en tiempo real violaciones críticas a:
  - R1: SQL crudo embebido en archivos Python de la aplicación Flask.
  - R2: Uso de jsonify o AJAX/fetch en la capa Flask/Jinja2.

Contrato Antigravity PreToolUse:
  - Lee JSON por stdin.
  - Devuelve JSON por stdout: {"decision": "allow"} o {"decision": "deny", "reason": "..."}.
  - Ante entradas inesperadas o archivos fuera del alcance de la app (scripts/, tests/, harness/,
    .agents/, sql/, docs/), siempre permite la operación para no generar falsos positivos.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

EXCLUDED_SEGMENTS = {
    ".agents",
    "harness",
    "scripts",
    "tests",
    "sql",
    "docs",
    ".venv",
    "venv",
}

RAW_SQL_IN_EXECUTE_RE = re.compile(
    r"""\.execute(?:many)?\s*\(\s*(?:[fFrRbBuU]*['"]{1,3})\s*(?!CALL\b|FETCH\s+ALL\s+FROM\b)"""
    r"""(SELECT|INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE|WITH)\b""",
    re.IGNORECASE,
)
JSONIFY_RE = re.compile(r"\bjsonify\s*\(|from\s+flask\s+import[^\n]*\bjsonify\b")
AJAX_RE = re.compile(
    r"\b(?:fetch\s*\(|XMLHttpRequest|axios\s*\.|\$\s*\.\s*(?:ajax|getJSON)\s*\()",
    re.IGNORECASE,
)


def allow() -> None:
    print(json.dumps({"decision": "allow"}))


def deny(reason: str) -> None:
    print(json.dumps({"decision": "deny", "reason": reason}, ensure_ascii=False))


def extract_target_and_text(payload: dict) -> tuple[str, str]:
    args = payload.get("toolCall", {}).get("args", {})
    if not isinstance(args, dict):
        return "", ""
    path_str = (
        args.get("Path")
        or args.get("TargetFile")
        or args.get("path")
        or ""
    )
    chunks = []
    for key in ("Content", "Replacement", "CodeContent", "ReplacementContent"):
        val = args.get(key)
        if isinstance(val, str):
            chunks.append(val)
    replacement_chunks = args.get("ReplacementChunks")
    if isinstance(replacement_chunks, list):
        for chunk in replacement_chunks:
            if isinstance(chunk, dict) and isinstance(chunk.get("ReplacementContent"), str):
                chunks.append(chunk["ReplacementContent"])
    return str(path_str), "\n".join(chunks)


def main() -> int:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            allow()
            return 0
        payload = json.loads(raw)
        path_str, text = extract_target_and_text(payload)
        if not path_str or not text:
            allow()
            return 0

        p = Path(path_str)
        parts_lower = {part.lower() for part in p.parts}
        if parts_lower & EXCLUDED_SEGMENTS:
            allow()
            return 0

        suffix = p.suffix.lower()
        if suffix == ".py":
            m_sql = RAW_SQL_IN_EXECUTE_RE.search(text)
            if m_sql:
                deny(
                    f"HARNESS R1 BLOQUEADO en {p.name}: se detectó SQL crudo (`{m_sql.group(1)}`) "
                    "dentro de .execute(). Todo acceso a PostgreSQL debe pasar por `CALL sp_...(...)` "
                    "o `FETCH ALL FROM <cursor>`. Consulta AGENTS.md."
                )
                return 0

            if JSONIFY_RE.search(text):
                deny(
                    f"HARNESS R2 BLOQUEADO en {p.name}: se detectó uso/importación de `jsonify`. "
                    "Toda conexión backend-frontend debe realizarse por Jinja2 (render_template / | tojson). "
                    "Consulta AGENTS.md."
                )
                return 0

        elif suffix in {".html", ".js"}:
            m_ajax = AJAX_RE.search(text)
            if m_ajax:
                deny(
                    f"HARNESS R2 BLOQUEADO en {p.name}: se detectó `{m_ajax.group(0)}`. "
                    "Prohibido AJAX/fetch/SPA; inyecta los datos desde Flask usando Jinja2. Consulta AGENTS.md."
                )
                return 0

        allow()
        return 0
    except Exception:
        # Fail-open para nunca bloquear herramientas por errores de parseo inesperados
        allow()
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
