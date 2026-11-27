#!/usr/bin/env python3
"""
Verificador del Harness — Sistema de Gestión Clínica (Equipo 01).

Valida determinísticamente:
  - R1: CERO SQL crudo en archivos Python de aplicación (solo CALL sp_... y FETCH ALL FROM ...).
  - R2: 100% SSR con Jinja2 (prohibido jsonify, fetch/XMLHttpRequest/axios/AJAX, rutas hardcodeadas).
  - Integridad de Stored Procedures: todo CALL en Python existe en SQL con aridad exacta.
  - Integridad de Flask y Jinja2: sintaxis Python/Jinja2, existencia de templates y endpoints en url_for.
  - Panel de cumplimiento progresivo (Fase 2+ y Rúbrica Final): reportado como advertencias en modo
    normal y exigido como error bloqueante con --strict.

Uso:
    python harness/verify_harness.py
    python harness/verify_harness.py --strict
"""

from __future__ import annotations

import ast
import builtins
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

try:
    from jinja2 import Environment, TemplateSyntaxError
except ImportError:
    Environment = None
    TemplateSyntaxError = Exception

ROOT = Path(__file__).resolve().parent.parent

# Directorios excluidos del escaneo de código de aplicación Flask
EXCLUDED_DIRS = {
    ".git",
    ".venv",
    "venv",
    "__pycache__",
    ".pytest_cache",
    ".agents",
    "harness",
    "scripts",
    "tests",
    "docs",
}

SQL_CALL_RE = re.compile(
    r"^\s*CALL\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\((.*)\)\s*;?\s*$",
    re.IGNORECASE | re.DOTALL,
)
SQL_FETCH_RE = re.compile(
    r"^\s*FETCH\s+ALL\s+FROM\s+[a-zA-Z_][a-zA-Z0-9_]*\s*;?\s*$",
    re.IGNORECASE,
)
FORBIDDEN_RAW_SQL_RE = re.compile(
    r"\b(?:SELECT\s+.+?\s+FROM|INSERT\s+INTO\s+\w+|UPDATE\s+\w+\s+SET|DELETE\s+FROM\s+\w+|"
    r"CREATE\s+(?:OR\s+REPLACE\s+)?(?:TABLE|VIEW|PROCEDURE|FUNCTION|TRIGGER)|"
    r"DROP\s+(?:TABLE|VIEW|PROCEDURE|FUNCTION|TRIGGER)|ALTER\s+TABLE|TRUNCATE\s+TABLE)\b",
    re.IGNORECASE | re.DOTALL,
)
AJAX_RE = re.compile(
    r"\b(?:fetch\s*\(|XMLHttpRequest|axios\s*\.|\$\s*\.\s*(?:ajax|getJSON|post|get)\s*\()",
    re.IGNORECASE,
)
HARDCODED_URL_RE = re.compile(
    r"""(?:href|action)\s*=\s*["']/(?!\{)[^"']*["']""",
    re.IGNORECASE,
)
TEMPLATE_URL_FOR_RE = re.compile(r"""url_for\(\s*['"]([a-zA-Z_][a-zA-Z0-9_.]*)['"]""")
CREATE_PROC_RE = re.compile(
    r"CREATE\s+(?:OR\s+REPLACE\s+)?PROCEDURE\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)\s*\((.*?)\)\s*LANGUAGE",
    re.IGNORECASE | re.DOTALL,
)


@dataclass
class Issue:
    code: str
    severity: str  # "ERROR" | "WARN"
    location: str
    message: str


@dataclass
class Report:
    errors: List[Issue] = field(default_factory=list)
    warnings: List[Issue] = field(default_factory=list)
    metrics: Dict[str, object] = field(default_factory=dict)

    def add_error(self, code: str, location: str, message: str) -> None:
        self.errors.append(Issue(code, "ERROR", location, message))

    def add_warn(self, code: str, location: str, message: str) -> None:
        self.warnings.append(Issue(code, "WARN", location, message))


def split_top_level_args(arg_str: str) -> List[str]:
    """Divide argumentos separados por coma respetando paréntesis y comillas simples."""
    cleaned = arg_str.strip()
    if not cleaned:
        return []
    args: List[str] = []
    buf: List[str] = []
    depth = 0
    in_single = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if ch == "'" and (i == 0 or cleaned[i - 1] != "\\"):
            in_single = not in_single
            buf.append(ch)
        elif not in_single:
            if ch == "(":
                depth += 1
                buf.append(ch)
            elif ch == ")":
                depth -= 1
                buf.append(ch)
            elif ch == "," and depth == 0:
                args.append("".join(buf).strip())
                buf = []
            else:
                buf.append(ch)
        else:
            buf.append(ch)
        i += 1
    if buf:
        args.append("".join(buf).strip())
    return args


def collect_app_python_files() -> List[Path]:
    files: List[Path] = []
    for path in sorted(ROOT.rglob("*.py")):
        rel_parts = set(path.relative_to(ROOT).parts[:-1])
        if rel_parts & EXCLUDED_DIRS:
            continue
        files.append(path)
    return files


def collect_sql_files() -> List[Path]:
    sql_files: List[Path] = []
    sql_dir = ROOT / "sql"
    if sql_dir.is_dir():
        sql_files.extend(sorted(sql_dir.glob("*.sql")))
    backup = ROOT / "backup_BD.sql"
    if backup.is_file():
        sql_files.append(backup)
    return sql_files


def parse_sql_catalog(sql_files: List[Path]) -> Dict[str, object]:
    procedures: Dict[str, Set[int]] = {}
    tables: Set[str] = set()
    views: Set[str] = set()
    triggers: Set[str] = set()
    temp_table_sps: Set[str] = set()

    for sf in sql_files:
        text = sf.read_text(encoding="utf-8", errors="replace")

        for match in CREATE_PROC_RE.finditer(text):
            name = match.group(1).lower()
            params = split_top_level_args(match.group(2))
            procedures.setdefault(name, set()).add(len(params))

            # Verificar si el cuerpo del SP crea tablas temporales
            body_start = match.end()
            body_end = text.find("$$;", body_start)
            if body_end != -1:
                body = text[body_start:body_end]
                if re.search(r"\bCREATE\s+(?:TEMP|TEMPORARY)\s+TABLE\b", body, re.IGNORECASE):
                    temp_table_sps.add(name)

        for m in re.finditer(
            r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)",
            text,
            re.IGNORECASE,
        ):
            tables.add(m.group(1).lower())

        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?VIEW\s+(?:public\.)?([a-zA-Z_][a-zA-Z0-9_]*)",
            text,
            re.IGNORECASE,
        ):
            views.add(m.group(1).lower())

        for m in re.finditer(
            r"CREATE\s+(?:OR\s+REPLACE\s+)?TRIGGER\s+([a-zA-Z_][a-zA-Z0-9_]*)",
            text,
            re.IGNORECASE,
        ):
            triggers.add(m.group(1).lower())

    return {
        "procedures": procedures,
        "tables": tables,
        "views": views,
        "triggers": triggers,
        "temp_table_sps": temp_table_sps,
    }


def collect_defined_names(tree: ast.AST) -> Set[str]:
    names: Set[str] = set(dir(builtins))
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                for arg in (
                    node.args.posonlyargs
                    + node.args.args
                    + node.args.kwonlyargs
                    + ([node.args.vararg] if node.args.vararg else [])
                    + ([node.args.kwarg] if node.args.kwarg else [])
                ):
                    names.add(arg.arg)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.asname or alias.name.split(".")[0])
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                names.add(alias.asname or alias.name)
        elif isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            names.add(node.id)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
    return names


def check_python_files(
    py_files: List[Path],
    sql_catalog: Dict[str, object],
    report: Report,
) -> Tuple[Set[str], List[Tuple[str, int, str, int]]]:
    endpoints: Set[str] = {"static"}
    sp_calls: List[Tuple[str, int, str, int]] = []
    procedures: Dict[str, Set[int]] = sql_catalog["procedures"]  # type: ignore[assignment]
    templates_dir = ROOT / "templates"

    for pf in py_files:
        rel = str(pf.relative_to(ROOT))
        source = pf.read_text(encoding="utf-8", errors="replace")
        try:
            tree = ast.parse(source, filename=rel)
        except SyntaxError as exc:
            report.add_error("PY-SYNTAX", f"{rel}:{exc.lineno}", f"Error de sintaxis Python: {exc.msg}")
            continue

        # Mapa simple de constantes de string asignadas en el archivo (para detectar query = "SELECT...")
        string_vars: Dict[str, str] = {}
        for node in ast.walk(tree):
            if isinstance(node, ast.Assign) and isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                for target in node.targets:
                    if isinstance(target, ast.Name):
                        string_vars[target.id] = node.value.value

        # 1. Revisar imports prohibidos (R2: jsonify)
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module == "flask":
                for alias in node.names:
                    if alias.name == "jsonify":
                        report.add_error(
                            "R2-NO-JSONIFY",
                            f"{rel}:{node.lineno}",
                            "Importación de `jsonify` prohibida: toda comunicación backend-frontend debe usar Jinja2.",
                        )

        # 2. Recolectar rutas Flask y verificar nombres no definidos (ej. flash)
        defined = collect_defined_names(tree)
        reported_undef: Set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.FunctionDef):
                for dec in node.decorator_list:
                    if isinstance(dec, ast.Call) and isinstance(dec.func, ast.Attribute) and dec.func.attr == "route":
                        endpoints.add(node.name)
            elif isinstance(node, ast.Name) and isinstance(node.ctx, ast.Load):
                if node.id not in defined and node.id not in reported_undef:
                    reported_undef.add(node.id)
                    report.add_warn(
                        "PY-UNDEFINED-NAME",
                        f"{rel}:{node.lineno}",
                        f"Identificador `{node.id}` usado sin importar o definir (revisar en Fase 2).",
                    )

        # 3. Revisar llamadas .execute / .executemany, render_template, url_for, jsonify
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue

            # R2: llamada a jsonify(...)
            if (isinstance(node.func, ast.Name) and node.func.id == "jsonify") or (
                isinstance(node.func, ast.Attribute) and node.func.attr == "jsonify"
            ):
                report.add_error(
                    "R2-NO-JSONIFY",
                    f"{rel}:{node.lineno}",
                    "Uso de `jsonify()` prohibido por regla R2 (100% Jinja2, sin SPA/REST JSON).",
                )

            # R2: render_template(...) debe apuntar a un archivo real
            if isinstance(node.func, ast.Name) and node.func.id == "render_template" and node.args:
                arg0 = node.args[0]
                if isinstance(arg0, ast.Constant) and isinstance(arg0.value, str):
                    tpl_path = templates_dir / arg0.value
                    if not tpl_path.is_file():
                        report.add_error(
                            "R2-TEMPLATE-MISSING",
                            f"{rel}:{node.lineno}",
                            f"Plantilla `{arg0.value}` referenciada en render_template() no existe en templates/.",
                        )

            # R1: .execute(...) / .executemany(...)
            if isinstance(node.func, ast.Attribute) and node.func.attr in {"execute", "executemany"}:
                if not node.args:
                    continue
                sql_node = node.args[0]
                if isinstance(sql_node, (ast.JoinedStr, ast.BinOp)):
                    report.add_error(
                        "R1-DYNAMIC-SQL",
                        f"{rel}:{node.lineno}",
                        "Prohibido construir SQL con f-strings o concatenación en .execute(); usa `CALL sp_...(%s)`.",
                    )
                    continue
                if isinstance(sql_node, ast.Call) and isinstance(sql_node.func, ast.Attribute) and sql_node.func.attr == "format":
                    report.add_error(
                        "R1-DYNAMIC-SQL",
                        f"{rel}:{node.lineno}",
                        "Prohibido usar .format() en .execute(); usa parámetros `%s` en `CALL sp_...`.",
                    )
                    continue

                sql_text: Optional[str] = None
                if isinstance(sql_node, ast.Constant) and isinstance(sql_node.value, str):
                    sql_text = sql_node.value
                elif isinstance(sql_node, ast.Name) and sql_node.id in string_vars:
                    sql_text = string_vars[sql_node.id]
                else:
                    report.add_error(
                        "R1-OPAQUE-SQL",
                        f"{rel}:{node.lineno}",
                        "Sentencia pasada a .execute() no es un literal verificable `CALL sp_...` ni `FETCH ALL FROM ...`.",
                    )
                    continue

                if SQL_FETCH_RE.match(sql_text):
                    continue

                call_match = SQL_CALL_RE.match(sql_text)
                if not call_match:
                    preview = " ".join(sql_text.strip().split())[:90]
                    report.add_error(
                        "R1-RAW-SQL",
                        f"{rel}:{node.lineno}",
                        f"SQL crudo prohibido en Python (solo se permite CALL sp_... o FETCH ALL FROM): `{preview}`",
                    )
                    continue

                sp_name = call_match.group(1).lower()
                call_args = split_top_level_args(call_match.group(2))
                for arg in call_args:
                    if FORBIDDEN_RAW_SQL_RE.search(arg):
                        report.add_error(
                            "R1-SUBQUERY-IN-CALL",
                            f"{rel}:{node.lineno}",
                            f"Subconsulta SQL embebida detectada dentro de CALL {sp_name}(...).",
                        )

                sp_calls.append((sp_name, len(call_args), rel, node.lineno))
                if procedures:
                    if sp_name not in procedures:
                        report.add_error(
                            "R1-SP-MISSING",
                            f"{rel}:{node.lineno}",
                            f"El Stored Procedure `{sp_name}` llamado desde Python no existe en backup_BD.sql ni sql/*.sql.",
                        )
                    elif len(call_args) not in procedures[sp_name]:
                        expected = sorted(procedures[sp_name])
                        report.add_error(
                            "R1-SP-ARITY",
                            f"{rel}:{node.lineno}",
                            f"`{sp_name}` recibe {len(call_args)} argumento(s), pero en SQL espera {expected}.",
                        )

        # 4. Revisar cadenas SQL crudas ocultas en literales del archivo
        for node in ast.walk(tree):
            if isinstance(node, ast.Constant) and isinstance(node.value, str):
                text = node.value
                if SQL_CALL_RE.match(text) or SQL_FETCH_RE.match(text):
                    continue
                if FORBIDDEN_RAW_SQL_RE.search(text):
                    preview = " ".join(text.strip().split())[:80]
                    report.add_error(
                        "R1-EMBEDDED-SQL-LITERAL",
                        f"{rel}:{getattr(node, 'lineno', 0)}",
                        f"Literal SQL embebido detectado en código Python: `{preview}`",
                    )

        # 5. Revisar url_for() en Python (segunda pasada tras recolectar endpoints)
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == "url_for" and node.args:
                arg0 = node.args[0]
                if isinstance(arg0, ast.Constant) and isinstance(arg0.value, str):
                    ep = arg0.value.split(".")[-1]
                    if ep not in endpoints:
                        report.add_error(
                            "R2-ENDPOINT-MISSING",
                            f"{rel}:{node.lineno}",
                            f"url_for('{arg0.value}') apunta a un endpoint inexistente en Flask.",
                        )

        # 6. Controles progresivos de seguridad (Fase 2 — WARN en normal, ERROR en --strict)
        if re.search(r"password_ingresada\s*==\s*password_bd|password_bd\s*==\s*password_ingresada", source):
            report.add_warn(
                "SEC-PLAINTEXT-PASSWORD",
                rel,
                "Comparación de contraseñas en texto plano detectada; migrar a werkzeug.security.check_password_hash (Fase 2).",
            )
        if re.search(r"^\s*DB_PASSWORD\s*=\s*['\"]", source, re.MULTILINE):
            report.add_warn(
                "SEC-HARDCODED-DB-CREDS",
                rel,
                "Credenciales de BD hardcodeadas en código; migrar a os.environ.get() + .env (Fase 2).",
            )
        if re.search(r"^\s*app\.secret_key\s*=\s*['\"]", source, re.MULTILINE):
            report.add_warn(
                "SEC-HARDCODED-SECRET-KEY",
                rel,
                "app.secret_key hardcodeada; cargar desde FLASK_SECRET_KEY en .env (Fase 2).",
            )
        if re.search(r"""^\s*print\(\s*["'].*conectada a la Base de Datos""", source, re.MULTILINE | re.IGNORECASE):
            report.add_warn(
                "OBS-BLIND-DB-PRINT",
                rel,
                "Mensaje print() afirmando conexión a BD antes de comprobar conexión real (feedback 2da entrega, Fase 2).",
            )

    return endpoints, sp_calls


def check_templates_and_static(endpoints: Set[str], report: Report) -> Dict[str, bool]:
    templates_dir = ROOT / "templates"
    static_js_dir = ROOT / "static" / "js"
    jinja_env = Environment() if Environment else None

    has_highcharts = False
    has_disclaimer = False

    if templates_dir.is_dir():
        for tpl in sorted(templates_dir.rglob("*.html")):
            rel = str(tpl.relative_to(ROOT))
            content = tpl.read_text(encoding="utf-8", errors="replace")

            # Sintaxis Jinja2
            if jinja_env is not None:
                try:
                    jinja_env.parse(content)
                except TemplateSyntaxError as exc:
                    report.add_error(
                        "R2-JINJA-SYNTAX",
                        f"{rel}:{exc.lineno}",
                        f"Error de sintaxis Jinja2: {exc.message}",
                    )

            # Bloqueo AJAX / fetch en templates
            ajax_match = AJAX_RE.search(content)
            if ajax_match:
                report.add_error(
                    "R2-NO-AJAX",
                    rel,
                    f"Llamada AJAX/fetch prohibida en template Jinja2 (`{ajax_match.group(0)}`).",
                )

            # Bloqueo rutas hardcodeadas en href/action
            for m in HARDCODED_URL_RE.finditer(content):
                report.add_error(
                    "R2-HARDCODED-URL",
                    rel,
                    f"Ruta hardcodeada `{m.group(0)}`; usa `{{{{ url_for(...) }}}}`.",
                )

            # Verificar endpoints en url_for('...')
            for m in TEMPLATE_URL_FOR_RE.finditer(content):
                ep = m.group(1).split(".")[-1]
                if ep not in endpoints:
                    report.add_error(
                        "R2-TEMPLATE-ENDPOINT",
                        rel,
                        f"url_for('{m.group(1)}') en template no coincide con ninguna ruta registrada en Flask.",
                    )

            # Hallazgo conocido de Fase 2 en nuevaAsignacion.html
            if tpl.name == "nuevaAsignacion.html" and "p[2]" in content:
                report.add_warn(
                    "BUG-TUPLE-INDEX",
                    rel,
                    "Referencia a `p[2]` detectada, pero sp_listar_pacientes_sin_asignar devuelve 2 columnas (Fase 2).",
                )

            if "Highcharts.chart" in content or "highcharts" in content.lower():
                has_highcharts = True
            if "no sustituye la atención profesional" in content.lower() or "emergencias" in content.lower():
                has_disclaimer = True

    if static_js_dir.is_dir():
        for js_file in sorted(static_js_dir.rglob("*.js")):
            rel = str(js_file.relative_to(ROOT))
            content = js_file.read_text(encoding="utf-8", errors="replace")
            ajax_match = AJAX_RE.search(content)
            if ajax_match:
                report.add_error(
                    "R2-NO-AJAX",
                    rel,
                    f"Llamada AJAX/fetch prohibida en JS (`{ajax_match.group(0)}`); inyecta datos vía Jinja2.",
                )

    return {"has_highcharts": has_highcharts, "has_disclaimer": has_disclaimer}


def check_rubric_readiness(
    sql_catalog: Dict[str, object],
    ui_flags: Dict[str, bool],
    report: Report,
) -> None:
    tables_n = len(sql_catalog["tables"])  # type: ignore[arg-type]
    views_n = len(sql_catalog["views"])  # type: ignore[arg-type]
    sps_n = len(sql_catalog["procedures"])  # type: ignore[arg-type]
    temp_sps_n = len(sql_catalog["temp_table_sps"])  # type: ignore[arg-type]
    triggers_n = len(sql_catalog["triggers"])  # type: ignore[arg-type]

    has_joins_doc = (ROOT / "sql" / "06_joins_y_consultas_avanzadas.sql").is_file()
    has_mongo = (ROOT / "mongo_db.py").is_file()
    has_etl = (ROOT / "etl" / "pipeline_clinico.py").is_file()
    has_tests = (ROOT / "tests").is_dir() and any((ROOT / "tests").glob("test_*.py"))

    report.metrics = {
        "tablas_pg": tables_n,
        "vistas_pg": views_n,
        "stored_procedures_pg": sps_n,
        "sp_con_tablas_temporales": temp_sps_n,
        "triggers_pg": triggers_n,
        "sql_joins_avanzados": has_joins_doc,
        "mongodb_integrado": has_mongo,
        "etl_implementado": has_etl,
        "highcharts_integrado": ui_flags["has_highcharts"],
        "aviso_clinico_ui": ui_flags["has_disclaimer"],
        "tests_pytest": has_tests,
    }

    if tables_n < 20:
        report.add_warn("RUBRIC-TABLES", "SQL", f"Se requieren >= 20 tablas (actual: {tables_n}).")
    if views_n < 5:
        report.add_warn("RUBRIC-VIEWS", "SQL", f"Se requieren >= 5 vistas (actual: {views_n}).")
    if sps_n < 20:
        report.add_warn("RUBRIC-SPS", "SQL", f"Se requieren >= 20 SPs (actual: {sps_n}).")
    if temp_sps_n < 3:
        report.add_warn(
            "RUBRIC-TEMP-TABLES",
            "SQL",
            f"Rúbrica exige >= 3 SPs con tablas temporales (actual: {temp_sps_n}) — planificado en Fase 3.",
        )
    if triggers_n < 5:
        report.add_warn(
            "RUBRIC-TRIGGERS",
            "SQL",
            f"Rúbrica exige >= 5 triggers (auditoría + integridad/reactivos; actual: {triggers_n}) — planificado en Fase 3.",
        )
    if not has_joins_doc:
        report.add_warn(
            "RUBRIC-JOINS",
            "sql/06_joins_y_consultas_avanzadas.sql",
            "Falta archivo documentado con los 7 tipos de JOIN, subconsultas, CTE y ventanas — Fase 3.",
        )
    if not has_mongo:
        report.add_warn("RUBRIC-MONGO", "mongo_db.py", "Integración de MongoDB pendiente — Fase 4.")
    if not has_etl:
        report.add_warn("RUBRIC-ETL", "etl/pipeline_clinico.py", "Pipeline ETL de preprocesamiento y análisis pendiente — Fase 6.")
    if not ui_flags["has_highcharts"]:
        report.add_warn("RUBRIC-HIGHCHARTS", "templates/", "Gráficas Highcharts pendientes — Fase 6.")
    if not ui_flags["has_disclaimer"]:
        report.add_warn("RUBRIC-DISCLAIMER", "templates/", "Aviso clínico/emergencias obligatorio pendiente — Fase 2.")
    if not has_tests:
        report.add_warn("RUBRIC-TESTS", "tests/", "Suite reproducible de pruebas pytest pendiente — Fase 7.")


def main() -> int:
    strict = "--strict" in sys.argv
    report = Report()

    py_files = collect_app_python_files()
    sql_files = collect_sql_files()
    sql_catalog = parse_sql_catalog(sql_files)

    endpoints, sp_calls = check_python_files(py_files, sql_catalog, report)
    ui_flags = check_templates_and_static(endpoints, report)
    check_rubric_readiness(sql_catalog, ui_flags, report)

    print("=" * 72)
    print(" HARNESS VERIFIER — Sistema de Gestión Clínica (Equipo 01)")
    print("=" * 72)
    print(f"Archivos Python auditados : {len(py_files)}")
    print(f"Archivos SQL auditados    : {len(sql_files)}")
    print(f"Rutas Flask detectadas    : {len(endpoints) - 1}")
    print(f"Llamadas CALL verificadas : {len(sp_calls)}")
    print("-" * 72)
    print("RESUMEN DE MÉTRICAS DE RÚBRICA:")
    for key, val in report.metrics.items():
        print(f"  - {key:<26}: {val}")

    if report.errors:
        print("\n[ERRORES CRÍTICOS DE HARNESS (BLOQUEANTES)]")
        for err in report.errors:
            print(f"  [ERROR] [{err.code}] {err.location} -> {err.message}")
    else:
        print("\n[OK] Cero violaciones críticas de arquitectura (R1 SP-exclusivo, R2 100% Jinja2, SPs y rutas válidos).")

    if report.warnings:
        tag = "ERRORES (--strict)" if strict else "PENDIENTES / ADVERTENCIAS DE FASES SIGUIENTES"
        print(f"\n[{tag}] ({len(report.warnings)})")
        for warn in report.warnings:
            print(f"  [WARN]  [{warn.code}] {warn.location} -> {warn.message}")

    print("=" * 72)
    if report.errors or (strict and report.warnings):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
