# AGENTS.md — Harness del Sistema de Gestión Clínica (Equipo 01)

Este archivo define las **reglas obligatorias de arquitectura, codificación, base de datos, seguridad y verificación** del proyecto **Plataforma web para seguimiento terapéutico y evaluación longitudinal de salud mental** (Bases de Datos Avanzadas — Equipo 01).

**Integrantes oficiales del Equipo 01 (3 integrantes):**
- Rebeca Laredo (`613587`)
- Santiago Cano García (`624360`)
- Carlos Enrique Aguilar Sánchez (`685718`)

> **Instrucción obligatoria para todo agente y colaborador:** Lee y respeta este documento **antes** de diseñar, editar o proponer cualquier cambio. Ninguna tarea está terminada hasta que `python harness/verify_harness.py` pase sin errores críticos.

---

## 1. Reglas Inquebrantables (Hard Constraints)

### R1 — Acceso a PostgreSQL EXCLUSIVO vía Stored Procedures (CERO SQL en Python)
- **PROHIBIDO** escribir sentencias SQL directas (`SELECT`, `INSERT`, `UPDATE`, `DELETE`, `CREATE`, `ALTER`, `DROP`, `WITH`, `TRUNCATE`) dentro de `app.py` o cualquier otro archivo `.py` de la aplicación (incluyendo rutas, servicios y scripts ETL).
- **Incumplir R1 baja el criterio de Stored Procedures de la rúbrica a Deficiente.**
- Las **ÚNICAS** sentencias permitidas dentro de `cur.execute(...)` en Python son:
  1. Llamadas a procedimientos almacenados con parámetros seguros `%s` y `NULL` literal para argumentos `OUT`:
     ```python
     cur.execute("CALL sp_registrar_paciente(%s, %s, %s, %s, %s, %s, %s, %s, NULL, NULL)", (correo, ...))
     ```
  2. Lectura de un `refcursor` abierto inmediatamente antes por un `CALL` dentro de la misma transacción:
     ```python
     cur.execute("CALL sp_consultar_pacientes(1, 'cursor_pacientes', NULL)")
     cur.execute("FETCH ALL FROM cursor_pacientes")
     ```
- **PROHIBIDO** armar queries con f-strings, `+`, `%` o `.format(...)`. Siempre pasar parámetros como tupla en el segundo argumento de `cur.execute(...)`.
- Toda lógica de negocio, agregación, filtro, validación de empalmes, cálculo de KPIs y consulta sobre vistas `vw_*` debe vivir dentro de un `CREATE [OR REPLACE] PROCEDURE` en PostgreSQL.

### R2 — Comunicación Backend ↔ Frontend 100% vía Jinja2 (Sin SPA ni REST JSON)
- **PROHIBIDO** usar `jsonify`, construir endpoints JSON/API REST de SPA, o hacer llamadas `fetch()`, `XMLHttpRequest`, `axios` o `$.ajax` desde templates o `static/js/`.
- **PROHIBIDO** introducir frameworks SPA (React, Vue, Angular, Svelte).
- Toda comunicación entre Flask y el navegador ocurre exclusivamente mediante:
  - `render_template('vista.html', ...)`
  - `redirect(url_for('endpoint', ...))` (patrón **PRG — Post/Redirect/Get** tras formularios `POST`)
  - `request.form`, `session`, `flash(...)` y `get_flashed_messages(with_categories=true)`
- Todos los enlaces, `action` de formularios y recursos estáticos en plantillas HTML **DEBEN** usar `{{ url_for(...) }}`. Prohibido hardcodear rutas `/pacientes` o `/static/...`.
- **Gráficas con Highcharts:** La ruta Flask invoca el SP de reporte correspondiente y pasa los datos ya estructurados al template con `render_template(..., datos_grafica=...)`, inyectándolos con Jinja2 (`{{ datos_grafica | tojson }}`). JavaScript se limita a inicialización de Highcharts y pequeñas confirmaciones/validaciones de UI.

### R3 — Baja Lógica Obligatoria (Sin `DELETE` en Entidades Clínicas)
- Nunca eliminar físicamente registros de entidades clínicas (`usuario`, `paciente`, `terapeuta`, `asignacion_terapeuta_paciente`, `sesion`, `plan_terapeutico`, `objetivo`).
- Usar siempre los catálogos de estado definidos en PostgreSQL:
  - `rol`: `1 = Administrador`, `2 = Terapeuta`, `3 = Paciente`
  - `estado_usuario`: `1 = Activo`, `2 = Inactivo`
  - `estado_paciente`: `1 = Activo`, `2 = Baja Lógica`, `3 = En Pausa`
  - `estado_terapeuta`: `1 = Activo`, `2 = Vacaciones`, `3 = Baja`
  - `estado_asignacion`: `1 = Vigente`, `2 = Finalizada`
  - `estado_sesion`: `1 = Programada`, `2 = Completada`, `3 = Cancelada`
  - `modalidad_sesion`: `1 = Presencial`, `2 = Virtual`
  - `estado_plan`: `1 = Activo`, `2 = Completado`
  - `estado_objetivo`: `1 = Pendiente`, `2 = Logrado`

### R4 — Seguridad, Hashes, Credenciales y Privacidad Clínica
- **Contraseñas:** Siempre hasheadas con `werkzeug.security` (`generate_password_hash` al registrar/actualizar y `check_password_hash` al autenticar). Prohibido comparar contraseñas en texto plano.
- **Secretos y conexión:** `FLASK_SECRET_KEY`, `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`, `DB_SSLMODE`, `MONGO_URI` y `MONGO_DB_NAME` deben cargarse desde variables de entorno (`.env` en local, nunca commiteado; `.env.example` versionado). Compatible con desarrollo local y **Google Cloud SQL + MongoDB Atlas**.
- **Control de acceso (RBAC + Propiedad del dato):**
  - Guardia global `@app.before_request` (`proteger_rutas`) que bloquea toda ruta no listada en `rutas_publicas = ['login', 'static']`.
  - **Administrador (`rol == 1`):** Catálogos globales (pacientes, terapeutas, asignaciones), agenda global, indicadores agregados anonimizados y auditoría. **NO** debe acceder a contenido clínico privado (bitácoras emocionales ni notas extensas privadas).
  - **Terapeuta (`rol == 2`):** Solo sus pacientes asignados (`terapeuta_id`), sus sesiones, planes/objetivos, cuestionarios, notas SOAP y alertas de sus propios pacientes.
  - **Paciente (`rol == 3`):** Solo su agenda (`paciente_id`), responder cuestionarios asignados, registrar/ver sus propias bitácoras emocionales y ver su avance de objetivos.
- **Aviso clínico obligatorio en UI:** Todas las páginas autenticadas y de acceso deben mostrar un aviso claro indicando que la plataforma es apoyo terapéutico/académico y **no sustituye la atención profesional ni debe utilizarse para emergencias**.

### R5 — Arquitectura Híbrida PostgreSQL + MongoDB
- **PostgreSQL (`BD`, esquema `public`, 3FN):** Datos administrativos y relacionales estructurados: usuarios, roles, permisos, auditoría, pacientes, terapeutas, especialidades, asignaciones, sesiones, planes terapéuticos, objetivos, historial numérico de avance, instrumentos/dimensiones/aplicaciones/resultados numéricos, alertas y referencias (`id_documento_mongo`).
- **MongoDB (Fase 4+, >= 4 colecciones):** Documentos clínicos flexibles:
  1. `cuestionarios_instrumentos` (plantillas dinámicas y respuestas abiertas/cerradas)
  2. `bitacoras_emocionales` (registros emocionales del paciente)
  3. `resumenes_sesion_soap` (transcripciones, notas SOAP y resúmenes automáticos simulados)
  4. `historial_ediciones_clinicas` (versiones y notas extensas del terapeuta)
- **Coordinación:** Toda operación combinada PG ↔ MongoDB debe mantener consistencia (compensar eliminando el documento en MongoDB si falla el SP en PostgreSQL, o hacer `ROLLBACK` en PostgreSQL si falla MongoDB).

### R6 — Estándares de Codificación y Nomenclatura
- **Idioma:** Todo en **español** (tablas, columnas, SPs, vistas, triggers, rutas Flask, comentarios, mensajes y `<html lang="es">`).
- **Convenciones SQL / PL/pgSQL:**
  - Identificadores en `snake_case` minúsculas; PKs como `id_<entidad>`.
  - Prefijos obligatorios: `sp_` (Stored Procedures), `vw_` (Vistas), `trg_` (Triggers), `fn_` (Funciones trigger), `p_` (parámetros de SP), `v_` (variables locales PL/pgSQL).
  - Todo SP incluye bloque `EXCEPTION WHEN OTHERS THEN ...` y devuelve `OUT p_mensaje VARCHAR` (y `OUT p_id_* INT := NULL` cuando aplique).
  - Mínimo **3 SPs de reportes/rankings/agregaciones** deben usar tablas temporales (`CREATE TEMP TABLE ... ON COMMIT DROP`).
  - Mantener `sql/` modular (`01_ddl.sql` … `06_joins_y_consultas_avanzadas.sql`) y respaldar siempre en `backup_BD.sql` vía `.\scripts\export_backup.ps1`.
- **Convenciones Flask y Jinja2:**
  - Usar siempre context managers o bloques `try/finally` para cerrar cursores/conexiones y ejecutar `commit()` / `rollback()`.
  - Respetar el **contrato posicional SP ↔ Template**: cuando una vista accede a tuplas por índice (`p[0]`, `s[5]`), documentar las columnas exactas del `refcursor` y validar que coincidan.
  - Reutilizar clases de `static/css/estilos.css` (`.contenedor`, `.grupo-form`, `.btn`, `.btn-primario`, `.btn-editar`, `.btn-borrar`, paleta azul `#1e3a8a`, `#1e40af`, `#2563eb`).
  - Usar `templates/base.html` (`{% extends "base.html" %}`) para evitar duplicación del `<nav>`, alertas `flash` y aviso clínico.

### R7 — Control de Versiones y Replicabilidad
- Mantener el repositorio Git limpio dentro de `ProyectoFinal/` (rama `main` estable, desarrollo en `dev` o `feature/*`, commits descriptivos en español).
- Nunca commitear `.env`, contraseñas, `.venv/`, `__pycache__/` ni archivos `.zip`/`.tar.gz`.

---

## 2. Mapa Actual del Proyecto (Línea Base)

### Estructura de archivos
- `app.py`: Monolito Flask (23 rutas + `@app.before_request`).
- `backup_BD.sql`: Respaldo PostgreSQL completo (30 tablas, 8 vistas `vw_*`, 32 SPs `sp_*`).
- `templates/`: 14 plantillas Jinja2 (`login`, `index`, `registros`, `insertar`, `actualizar`, `terapeutas`, `insertarTerapeuta`, `actualizarTerapeuta`, `asignaciones`, `nuevaAsignacion`, `misPacientes`, `sesiones`, `nuevaSesion`, `errorAgenda`).
- `static/css/estilos.css` y `static/js/`.
- `scripts/setup_db.ps1` y `scripts/export_backup.ps1`: Restauración y respaldo local en PostgreSQL 17.
- `harness/verify_harness.py`: Verificador automatizado de reglas y progreso contra rúbrica.

### Variables de sesión estándar
| Clave en `session` | Rol que la usa | Descripción |
| :--- | :--- | :--- |
| `usuario_id` | Todos (1, 2, 3) | ID en tabla `usuario` |
| `usuario_rol` | Todos (1, 2, 3) | `1=Admin`, `2=Terapeuta`, `3=Paciente` |
| `usuario_correo` | Todos (1, 2, 3) | Correo electrónico autenticado |
| `terapeuta_id` | Terapeuta (2) | ID en tabla `terapeuta` |
| `paciente_id` | Paciente (3) | ID en tabla `paciente` |

### Vistas existentes (`vw_*`) y su integración esperada vía SP
| Vista | Estado actual | Integración objetivo en Flask (vía SP) |
| :--- | :--- | :--- |
| `vw_agenda_global` | Integrada (`sp_consultar_agenda_*`) | `/sesiones` |
| `vw_asignaciones_vigentes` | Integrada (`sp_consultar_asignaciones_vigentes`) | `/asignaciones`, `/nuevaSesion` |
| `vw_directorio_pacientes` | Definida en BD | `/pacientes` y reportes |
| `vw_directorio_terapeutas` | Definida en BD | `/terapeutas` y reportes |
| `vw_progreso_clinico` | Definida en BD | `/planes` y `/reportes` |
| `vw_alertas_activas` | Definida en BD | `/alertas` |
| `vw_resultados_instrumentos` | Definida en BD | `/instrumentos` y `/seguimiento` |
| `vw_reporte_auditoria` | Definida en BD | `/auditoria` (solo Admin) |

### Contratos posicionales críticos de SPs activos (resumen)
- `sp_consultar_metricas_dashboard`: `(pacientes, terapeutas, asignaciones, citas_hoy)`
- `sp_consultar_pacientes`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: telefono)`
- `sp_obtener_paciente_por_id`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: fecha_nac, 5: sexo, 6: telefono)`
- `sp_consultar_terapeutas` / `sp_obtener_terapeuta_por_id`: `(0: id_terapeuta, 1: nombre, 2: ap_pat, 3: ap_mat, 4: cedula)`
- `sp_consultar_asignaciones_vigentes`: `(0: id_asignacion, 1: terapeuta_encargado, 2: paciente_asignado, 3: fecha_inicio)`
- `sp_listar_pacientes_sin_asignar`: `(0: id_paciente, 1: nombre_completo)` *(2 columnas exactas)*
- `sp_consultar_agenda_*`: `(0: id_sesion, 1: fecha, 2: hora_inicio, 3: hora_fin, 4: modalidad, 5: estado_sesion, 6: terapeuta, 7: paciente)`
- `sp_consultar_mis_pacientes`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: fecha_nac, 5: sexo, 6: telefono)`

### Deuda técnica identificada (a resolver en Fase 2+)
1. `app.py` usa `flash(...)` sin importarlo desde `flask`.
2. `app.py` compara contraseñas en texto plano (`password_ingresada == password_bd`), hardcodea `DB_PASSWORD = ''` y `secret_key`, y tiene `print("Aplicacion conectada...")` sin verificar conexión real.
3. Faltan controles RBAC en rutas CRUD de Admin (`/insertar`, `/registra`, `/editar`, `/actualizar`, `/borrar`, `/insertarTerapeuta`, `/registra-terapeuta`, `/editarTerapeuta`, `/actualizar-terapeuta`, `/borrarTerapeuta`, `/nuevaAsignacion`, `/registra-asignacion`), propiedad en sesiones, y `id_admin = 1` está hardcodeado.
4. `nuevaAsignacion.html` referencia `p[2]` aunque `sp_listar_pacientes_sin_asignar` solo retorna 2 columnas (`p[0]`, `p[1]`).
5. Pendientes de rúbrica final: triggers (>= 5, auditoría + reactivos), >= 3 SPs con tablas temporales, `sql/06_joins_y_consultas_avanzadas.sql` completo, MongoDB (>= 4 colecciones), flujo de consulta/transcripción/Nota SOAP, planes/objetivos/cuestionarios/bitácoras, ETL de preprocesamiento y análisis, Highcharts, reportes descargables, pruebas `pytest` y despliegue GCP + `ubiquitous.udem.edu`.

---

## 3. Protocolo Obligatorio de Verificación (Definition of Done)

Antes de considerar completado cualquier cambio en el repositorio:

1. **Ejecutar el verificador del harness:**
   ```powershell
   python harness/verify_harness.py
   ```
   *(A partir de completadas las Fases 2–6, ejecutar también `python harness/verify_harness.py --strict`.)*
2. **Si modificaste PostgreSQL:**
   - Actualizar los scripts en `sql/` y regenerar `backup_BD.sql` con `.\scripts\export_backup.ps1`.
   - Actualizar la sección de contratos en `AGENTS.md` si agregaste SPs, vistas o rutas.
3. **Ejecutar pruebas automatizadas** (`python -m pytest -v` a partir de Fase 7).
4. **Registrar el avance en Git** con un commit claro y atómico en español (verificando con `git status` que `.env` no esté rastreado).
