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
- `app.py`: Monolito Flask organizado en 12 secciones (27 rutas + `@app.before_request` + `@rol_requerido`, `.env`, hashes Werkzeug).
- `backup_BD.sql`: Respaldo PostgreSQL completo (30 tablas, 8 vistas `vw_*`, 51 SPs `sp_*` — 4 con tablas temporales —, 9 triggers `trg_*`).
- `sql/`: Scripts SQL versionados (`01_indices_integridad.sql`, `03_triggers.sql`, `04_fase2_seguridad_sp.sql`, `04_fase3_sp_avanzados.sql`, `05_seed_data_fase3.sql`, `06_joins_y_consultas_avanzadas.sql`).
- `templates/`: Plantilla base `base.html` + 17 plantillas Jinja2 (incluyendo `alertas.html`, `reportes.html`, `auditoria.html`) con aviso clínico obligatorio.
- `static/css/estilos.css` y `static/js/`.
- `scripts/`: `setup_db.ps1`, `export_backup.ps1`, `migrar_passwords_seed.py`.
- `harness/verify_harness.py`: Verificador automatizado de reglas y progreso contra rúbrica.

### Variables de sesión estándar
| Clave en `session` | Rol que la usa | Descripción |
| :--- | :--- | :--- |
| `usuario_id` | Todos (1, 2, 3) | ID en tabla `usuario` |
| `usuario_rol` | Todos (1, 2, 3) | `1=Admin`, `2=Terapeuta`, `3=Paciente` |
| `usuario_correo` | Todos (1, 2, 3) | Correo electrónico autenticado |
| `terapeuta_id` | Terapeuta (2) | ID en tabla `terapeuta` |
| `paciente_id` | Paciente (3) | ID en tabla `paciente` |

### Vistas existentes (`vw_*`) — 8 de 8 integradas desde Flask vía SP
| Vista | Estado actual | Integración en Flask (vía SP) |
| :--- | :--- | :--- |
| `vw_agenda_global` | Integrada (`sp_consultar_agenda_*`) | `/sesiones` |
| `vw_asignaciones_vigentes` | Integrada (`sp_consultar_asignaciones_*`) | `/asignaciones`, `/nuevaSesion` |
| `vw_directorio_pacientes` | Integrada (`sp_consultar_directorio_pacientes`) | `/reportes?vista=directorio_pacientes` |
| `vw_directorio_terapeutas` | Integrada (`sp_consultar_directorio_terapeutas`, `sp_reporte_ranking_terapeutas`) | `/terapeutas`, `/reportes?vista=directorio_terapeutas`, `/reportes?vista=ranking` |
| `vw_progreso_clinico` | Integrada (`sp_consultar_progreso_clinico`) | `/reportes?vista=progreso` |
| `vw_alertas_activas` | Integrada (`sp_consultar_alertas_activas`) | `/alertas` |
| `vw_resultados_instrumentos` | Integrada (`sp_consultar_resultados_instrumentos`, `sp_reporte_evolucion_longitudinal`) | `/reportes?vista=instrumentos`, `/reportes?vista=evolucion` |
| `vw_reporte_auditoria` | Integrada (`sp_consultar_auditoria`) | `/auditoria` (solo Admin) |

### SPs con Tablas Temporales (`CREATE TEMP TABLE ... ON COMMIT DROP`)
1. `sp_reporte_ranking_terapeutas`: Ranking con `RANK() OVER`, tasa de cumplimiento y carga por terapeuta.
2. `sp_reporte_evolucion_longitudinal`: Evolución de instrumentos con `LAG()` y `AVG() OVER` por paciente/dimensión.
3. `sp_reporte_avance_planes`: Consolidación de objetivos logrados y avance promedio por plan con CTE.
4. `sp_reporte_indicadores_anonimizados`: KPIs agregados por cohorte etaria y modalidad sin exposición de PII.

### Triggers activos en PostgreSQL (`sql/03_triggers.sql` — 9 triggers)
- **Auditoría (6):** `trg_auditoria_paciente`, `trg_auditoria_terapeuta`, `trg_auditoria_asignacion`, `trg_auditoria_sesion`, `trg_auditoria_plan_terapeutico`, `trg_auditoria_objetivo` (`fn_auditoria_clinica`).
- **Integridad y lógica reactiva (3):** `trg_validar_sesion_integridad`, `trg_alerta_riesgo_instrumento` (alerta automática si puntuación >= 15), `trg_progreso_reactivo_objetivo` (avance 100% marca objetivo Logrado y completa plan).

### Contratos posicionales críticos de SPs activos (resumen)
- `sp_verificar_conexion`: `(ok, mensaje)`
- `sp_obtener_usuario_login`: `(id_usuario, id_rol, password_hash, id_estado_usuario, mensaje)`
- `sp_registrar_acceso_usuario`: `(mensaje)`
- `sp_consultar_metricas_dashboard`: `(pacientes_activos, terapeutas_activos, asignaciones_vigentes, citas_hoy_activas)`
- `sp_consultar_pacientes`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: telefono)`
- `sp_obtener_paciente_por_id`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: fecha_nac, 5: sexo, 6: telefono)`
- `sp_consultar_terapeutas` / `sp_obtener_terapeuta_por_id`: `(0: id_terapeuta, 1: nombre, 2: ap_pat, 3: ap_mat, 4: cedula)`
- `sp_consultar_asignaciones_vigentes` / `sp_consultar_asignaciones_terapeuta`: `(0: id_asignacion, 1: terapeuta_encargado, 2: paciente_asignado, 3: fecha_inicio)`
- `sp_validar_propiedad_asignacion` / `sp_validar_propiedad_sesion`: `(autorizado_bool, mensaje)`
- `sp_listar_pacientes_sin_asignar`: `(0: id_paciente, 1: nombre_completo)` *(2 columnas exactas)*
- `sp_consultar_agenda_*`: `(0: id_sesion, 1: fecha, 2: hora_inicio, 3: hora_fin, 4: modalidad, 5: estado_sesion, 6: terapeuta, 7: paciente)`
- `sp_consultar_mis_pacientes`: `(0: id_paciente, 1: nombre, 2: ap_pat, 3: ap_mat, 4: fecha_nac, 5: sexo, 6: telefono)`

### Pendientes de fases siguientes (Fases 4–7)
- **Fase 4:** MongoDB (`>= 4` colecciones clínicas flexibles + coordinación con PostgreSQL).
- **Fase 5:** Flujo completo de consulta/transcripción/Nota SOAP, planes terapéuticos, objetivos, cuestionarios psicométricos simulados y bitácoras emocionales.
- **Fase 6:** Pipeline ETL de preprocesamiento/análisis, tableros Highcharts (vía Jinja2 `| tojson`) y reportes descargables (CSV/XLSX/PDF).
- **Fase 7:** Suite `pytest`, despliegue en Google Cloud Platform (Compute Engine + Cloud SQL + MongoDB Atlas) y `ubiquitous.udem.edu`, documentación final y paquete `.zip`/`.tar.gz`.

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
