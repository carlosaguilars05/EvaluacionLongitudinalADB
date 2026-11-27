#!/usr/bin/env python3
"""
Migra las contraseñas en texto plano o hashes dummy de la tabla `usuario`
a hashes seguros de Werkzeug (scrypt) invocando EXCLUSIVAMENTE Stored Procedures.

- Contraseñas en texto plano (ej. '12345' de admin/paola.terapeuta/carlos.paciente):
  se hashean conservando su misma clave original para que sigan funcionando al iniciar sesión.
- Hashes ficticios de datos semilla ('scrypt:32768:8:1$dummy$...'):
  se reemplazan por el hash seguro de la contraseña de prueba 'Clinica2026!'.
- Hashes reales ya generados por Werkzeug: se omiten (operación idempotente).
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv
from werkzeug.security import generate_password_hash

ROOT = Path(__file__).resolve().parent.parent
load_dotenv(ROOT / ".env")

DEFAULT_DUMMY_PASSWORD = os.environ.get("SEED_DEFAULT_PASSWORD", "Clinica2026!")


def es_hash_werkzeug_real(valor: str | None) -> bool:
    if not valor:
        return False
    if "$dummy$" in valor:
        return False
    return valor.startswith(("scrypt:", "pbkdf2:")) and valor.count("$") >= 2


def main() -> int:
    conn = psycopg.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ.get("DB_NAME", "BD"),
        user=os.environ.get("DB_USER", "usuario"),
        password=os.environ.get("DB_PASSWORD", ""),
    )

    migrados_plano = 0
    migrados_dummy = 0
    omitidos = 0

    try:
        with conn.cursor() as cur:
            cur.execute("CALL sp_listar_usuarios_para_migracion('cursor_usuarios_mig', NULL)")
            cur.execute("FETCH ALL FROM cursor_usuarios_mig")
            usuarios = cur.fetchall()

            for id_usuario, correo, password_actual in usuarios:
                if es_hash_werkzeug_real(password_actual):
                    omitidos += 1
                    continue

                if password_actual and "$dummy$" in password_actual:
                    nuevo_hash = generate_password_hash(DEFAULT_DUMMY_PASSWORD)
                    migrados_dummy += 1
                else:
                    clave_origen = password_actual or DEFAULT_DUMMY_PASSWORD
                    nuevo_hash = generate_password_hash(clave_origen)
                    migrados_plano += 1

                cur.execute(
                    "CALL sp_actualizar_password_usuario(%s, %s, NULL)",
                    (id_usuario, nuevo_hash),
                )

        conn.commit()
    except Exception as exc:
        conn.rollback()
        print(f"[ERROR] Falló la migración de contraseñas: {exc}", file=sys.stderr)
        return 1
    finally:
        conn.close()

    print(
        f"[OK] Migración completada -> texto plano migrados: {migrados_plano}, "
        f"dummy migrados: {migrados_dummy}, ya hasheados: {omitidos}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
