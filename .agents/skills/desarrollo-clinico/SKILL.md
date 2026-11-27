---
name: desarrollo-clinico
description: >-
  Runbook obligatorio para agregar o modificar cualquier módulo, ruta, vista,
  Stored Procedure, trigger o plantilla Jinja2 en el Sistema de Gestión Clínica
  (Equipo 01), respetando AGENTS.md y el verificador del harness.
---

# Desarrollo de Módulos — Sistema de Gestión Clínica

Usa este procedimiento siempre que implementes o corrijas una funcionalidad en el proyecto.

## Paso 1: Revisar reglas y contratos
1. Consulta [AGENTS.md](../../../AGENTS.md) para confirmar:
   - Regla **R1**: Cero SQL crudo en Python (solo `CALL sp_...` y `FETCH ALL FROM <cursor>`).
   - Regla **R2**: 100% SSR con Jinja2 (sin `jsonify`, sin `fetch`/AJAX, todo enlace con `url_for()`).
   - Regla **R3**: Baja lógica únicamente (usar catálogos `estado_*`).
   - Regla **R4**: RBAC por rol (`1=Admin`, `2=Terapeuta`, `3=Paciente`) y propiedad del dato.
   - Regla **R5**: Separación PostgreSQL vs MongoDB.

## Paso 2: Capa de Base de Datos (PostgreSQL y/o MongoDB)
1. Si requiere datos relacionales, define primero los cambios en los scripts de `sql/`:
   - Vistas legibles con prefijo `vw_`.
   - Triggers de auditoría/integridad con prefijo `trg_` y función `fn_`.
   - Stored Procedures con prefijo `sp_`, parámetros `p_`, variables `v_`, `OUT p_mensaje VARCHAR` y bloque `EXCEPTION WHEN OTHERS`.
   - En SPs de reportes/rankings/agregaciones complejos, emplea `CREATE TEMP TABLE ... ON COMMIT DROP`.
2. Si requiere documentos clínicos flexibles (cuestionarios, bitácoras, transcripciones/Nota SOAP, notas extensas), implementa el acceso en `mongo_db.py` y enlaza el `_id` en PostgreSQL (`id_documento_mongo`) vía SP con compensación ante error.

## Paso 3: Capa Backend Flask (`app.py`)
1. Protege la ruta con el control de rol y propiedad correspondiente.
2. Ejecuta únicamente `cur.execute("CALL sp_...(%s, ...)", (...))` y, si aplica `refcursor`, `cur.execute("FETCH ALL FROM <cursor>")`.
3. Cierra siempre cursor y conexión (con `commit()` o `rollback()` según corresponda).
4. Retorna exclusivamente `render_template(...)` o `redirect(url_for(...))` (patrón PRG). Para Highcharts, inyecta datos serializables al template para usarlos con `{{ datos | tojson }}`.

## Paso 4: Capa Frontend Jinja2 (`templates/`)
1. Usa HTML5 en español (`lang="es"`) y las clases de `static/css/estilos.css` (heredando de `base.html` a partir de Fase 2).
2. Usa `{{ url_for(...) }}` en todos los enlaces, formularios y recursos estáticos.
3. Verifica que los índices posicionales (`fila[0]`, `fila[1]`, ...) coincidan exactamente con las columnas del `SELECT` del `refcursor` en el SP.

## Paso 5: Verificación obligatoria y respaldo
1. Ejecuta el verificador del harness:
   ```powershell
   python harness/verify_harness.py
   ```
2. Si modificaste la BD local, actualiza el respaldo:
   ```powershell
   .\scripts\export_backup.ps1
   ```
3. Si existen pruebas automatizadas, ejecútalas con `pytest -v`.
4. Registra el cambio en Git (`git status` -> `git add` -> `git commit`).
