"""
Sistema de Gestión Clínica (Equipo 01) — Backend Flask + Jinja2 + PostgreSQL (SP exclusivo).

Estructura del archivo:
  1. Configuración e Infraestructura (variables de entorno, Flask, conexión BD y auditoría)
  2. Seguridad y Control de Acceso (RBAC y guardia global)
  3. Autenticación (/login, /logout)
  4. Inicio / Dashboard (/)
  5. Módulo de Pacientes (/pacientes, /mis_pacientes, CRUD y baja lógica)
  6. Módulo de Terapeutas (/terapeutas, CRUD y baja lógica)
  7. Módulo de Asignaciones (/asignaciones, vinculación terapeuta-paciente)
  8. Módulo de Agenda y Sesiones (/sesiones, agendar y cancelar)
  9. Módulo de Alertas Clínicas (/alertas, atención de alertas — vw_alertas_activas)
 10. Módulo de Reportes Avanzados (/reportes — 4 SPs con tablas temporales y vistas vw_*)
 11. Módulo de Auditoría (/auditoria — vw_reporte_auditoria, Solo Admin)
 12. Punto de Entrada (__main__)
"""

from functools import wraps
import os
import secrets

from dotenv import load_dotenv
from flask import Flask, flash, redirect, render_template, request, session, url_for
import psycopg
from werkzeug.security import check_password_hash, generate_password_hash

import mongo_db


# ==============================================================================
# 1. Configuración e Infraestructura
# ==============================================================================
load_dotenv()

app = Flask(__name__)

_secret_key = os.environ.get("FLASK_SECRET_KEY")
if not _secret_key:
    _secret_key = secrets.token_hex(32)
    app.logger.warning(
        "FLASK_SECRET_KEY no definida en el entorno; se generó una clave efímera para esta ejecución."
    )

app.secret_key = _secret_key
app.config["SESSION_COOKIE_HTTPONLY"] = True
app.config["SESSION_COOKIE_SAMESITE"] = "Lax"
app.config["SESSION_COOKIE_SECURE"] = os.environ.get("FLASK_COOKIE_SECURE", "false").lower() == "true"

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "BD")
DB_USER = os.environ.get("DB_USER", "usuario")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_SSLMODE = os.environ.get("DB_SSLMODE", "prefer")


def conectar():
    """Abre una conexión segura a PostgreSQL (TCP o Unix socket de Cloud SQL)."""
    params = {
        "host": DB_HOST,
        "dbname": DB_NAME,
        "user": DB_USER,
        "password": DB_PASSWORD,
    }
    if not DB_HOST.startswith("/"):
        params["port"] = DB_PORT
        params["sslmode"] = DB_SSLMODE
    return psycopg.connect(**params)


def verificar_conexion_bd():
    """Comprueba la conexión real a PostgreSQL ejecutando un Stored Procedure."""
    try:
        with conectar() as conexion:
            with conexion.cursor() as cur:
                cur.execute("CALL sp_verificar_conexion(NULL, NULL)")
                ok, mensaje = cur.fetchone()
        return bool(ok), mensaje
    except Exception as exc:
        return False, f"No se pudo conectar a PostgreSQL: {exc}"


def establecer_contexto_auditoria(cur):
    """Configura usuario autenticado e IP de la petición para los triggers de auditoría."""
    cur.execute(
        "CALL sp_establecer_contexto_auditoria(%s, %s, NULL)",
        (session.get("usuario_id"), request.remote_addr or "127.0.0.1"),
    )


# ==============================================================================
# 2. Seguridad y Control de Acceso (RBAC)
# ==============================================================================
def rol_requerido(*roles_permitidos):
    """Decorador RBAC: restringe el acceso a los roles autorizados (1=Admin, 2=Terapeuta, 3=Paciente)."""
    def decorador(vista):
        @wraps(vista)
        def envuelta(*args, **kwargs):
            rol_actual = session.get("usuario_rol")
            if rol_actual not in roles_permitidos:
                flash("Acceso denegado. No cuentas con permisos para esta sección.", "error")
                if rol_actual == 1:
                    return redirect(url_for("principal"))
                return redirect(url_for("sesiones"))
            return vista(*args, **kwargs)
        return envuelta
    return decorador


@app.before_request
def proteger_rutas():
    """Guardia global: exige sesión autenticada para toda ruta no pública."""
    rutas_publicas = ["login", "static"]
    if request.endpoint not in rutas_publicas and "usuario_id" not in session:
        return redirect(url_for("login"))


# ==============================================================================
# 3. Autenticación (Login / Logout con hashes seguros Werkzeug)
# ==============================================================================
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "GET" and "usuario_id" in session:
        return redirect(url_for("principal"))

    if request.method == "POST":
        correo = (request.form.get("correo") or "").strip()
        password_ingresada = request.form.get("password") or ""

        with conectar() as conexion:
            with conexion.cursor() as cur:
                cur.execute("CALL sp_obtener_usuario_login(%s, NULL, NULL, NULL, NULL, NULL)", (correo,))
                id_usuario, id_rol, password_hash_bd, id_estado, mensaje_bd = cur.fetchone()

                if id_usuario is None:
                    flash(mensaje_bd or "El correo no existe en el sistema.", "error")
                elif id_estado != 1:
                    flash("Tu cuenta se encuentra inactiva. Contacta al administrador.", "error")
                elif not password_hash_bd or not check_password_hash(password_hash_bd, password_ingresada):
                    flash("Contraseña incorrecta.", "error")
                else:
                    session.clear()
                    session["usuario_id"] = id_usuario
                    session["usuario_rol"] = id_rol
                    session["usuario_correo"] = correo

                    if id_rol == 2:
                        cur.execute("CALL sp_consultar_terapeuta_usuario(%s, NULL)", (id_usuario,))
                        datos_terapeuta = cur.fetchone()
                        if datos_terapeuta and datos_terapeuta[0] is not None:
                            session["terapeuta_id"] = datos_terapeuta[0]
                    elif id_rol == 3:
                        cur.execute("CALL sp_consultar_paciente_usuario(%s, NULL)", (id_usuario,))
                        datos_paciente = cur.fetchone()
                        if datos_paciente and datos_paciente[0] is not None:
                            session["paciente_id"] = datos_paciente[0]

                    cur.execute("CALL sp_registrar_acceso_usuario(%s, NULL)", (id_usuario,))
                    conexion.commit()
                    flash("Sesión iniciada correctamente.", "success")
                    return redirect(url_for("principal"))

            conexion.commit()

    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    flash("Has cerrado sesión correctamente.", "success")
    return redirect(url_for("login"))


# ==============================================================================
# 4. Inicio / Dashboard (Admin)
# ==============================================================================
@app.route("/")
def principal():
    rol = session.get("usuario_rol")
    if rol in (2, 3):
        return redirect(url_for("sesiones"))

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_metricas_dashboard(NULL, NULL, NULL, NULL)")
            resultado = cur.fetchone()
        conexion.commit()

    metricas = {
        "pacientes": resultado[0],
        "terapeutas": resultado[1],
        "asignaciones": resultado[2],
        "citas_hoy": resultado[3],
    }
    mongo_ok, mongo_msg, mongo_conteos = mongo_db.verificar_conexion_mongo()
    estado_mongo = {
        "ok": mongo_ok,
        "mensaje": mongo_msg,
        "conteos": mongo_conteos,
    }
    return render_template("index.html", metricas=metricas, estado_mongo=estado_mongo)


# ==============================================================================
# 5. Módulo de Pacientes (Directorio Admin, Mis Pacientes Terapeuta y CRUD)
# ==============================================================================
@app.route("/pacientes")
@rol_requerido(1)
def pacientes():
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_pacientes(1, 'cursor_pacientes', NULL)")
            cur.execute("FETCH ALL FROM cursor_pacientes")
            lista_pacientes = cur.fetchall()
    return render_template("registros.html", Pacientes=lista_pacientes)


@app.route("/mis_pacientes")
@rol_requerido(2)
def mis_pacientes():
    id_terapeuta = session.get("terapeuta_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_mis_pacientes(%s, 'cursor_mis_pacientes')", (id_terapeuta,))
            cur.execute("FETCH ALL FROM cursor_mis_pacientes")
            lista_mis_pacientes = cur.fetchall()

    return render_template("misPacientes.html", pacientes=lista_mis_pacientes)


@app.route("/insertar")
@rol_requerido(1)
def insertar():
    return render_template("insertar.html")


@app.route("/registra", methods=["POST"])
@rol_requerido(1)
def registra():
    correo = (request.form.get("correo") or "").strip()
    password_plana = request.form.get("password_hash") or request.form.get("password") or ""
    nombres = (request.form.get("nombres") or "").strip()
    apellido_paterno = (request.form.get("apellido_paterno") or "").strip()
    apellido_materno = (request.form.get("apellido_materno") or "").strip() or None
    fecha_n = request.form.get("fecha_nacimiento")
    sexo = request.form.get("sexo") or None
    tel = (request.form.get("telefono") or "").strip() or None

    if not correo or not password_plana or not nombres or not apellido_paterno or not fecha_n:
        flash("Por favor completa todos los campos obligatorios.", "error")
        return redirect(url_for("insertar"))

    password_segura = generate_password_hash(password_plana)

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_registrar_paciente(%s, %s, %s, %s, %s, %s, %s, %s, NULL, NULL)",
                (correo, password_segura, nombres, apellido_paterno, apellido_materno, fecha_n, sexo, tel),
            )
            id_nuevo, mensaje_bd = cur.fetchone()
        conexion.commit()

    categoria = "success" if id_nuevo is not None else "error"
    flash(mensaje_bd, categoria)
    return redirect(url_for("pacientes"))


@app.route("/editar/<int:id_paciente>", methods=["GET"])
@rol_requerido(1)
def editar(id_paciente):
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_obtener_paciente_por_id(%s, 'cursor_paciente', NULL)", (id_paciente,))
            cur.execute("FETCH ALL FROM cursor_paciente")
            paciente = cur.fetchone()

    if paciente is None:
        flash("Paciente no encontrado.", "error")
        return redirect(url_for("pacientes"))

    return render_template("actualizar.html", Paciente=paciente)


@app.route("/actualizar", methods=["POST"])
@rol_requerido(1)
def actualizar():
    id_paciente = request.form.get("id_paciente")
    tel = (request.form.get("telefono") or "").strip() or None
    nombres = (request.form.get("nombres") or "").strip()
    apellido_paterno = (request.form.get("apellido_paterno") or "").strip()
    apellido_materno = (request.form.get("apellido_materno") or "").strip() or None

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_actualizar_paciente(%s, %s, %s, %s, %s, NULL)",
                (id_paciente, tel, nombres, apellido_paterno, apellido_materno),
            )
            (mensaje_bd,) = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success")
    return redirect(url_for("pacientes"))


@app.route("/borrar/<int:id_paciente>", methods=["POST"])
@rol_requerido(1)
def borrar(id_paciente):
    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute("CALL sp_dar_baja_paciente(%s, NULL)", (id_paciente,))
            (mensaje_bd,) = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success")
    return redirect(url_for("pacientes"))


# ==============================================================================
# 6. Módulo de Terapeutas (Solo Administrador - Rol 1)
# ==============================================================================
@app.route("/terapeutas")
@rol_requerido(1)
def terapeutas():
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_terapeutas(1, 'cursor_terapeutas', NULL)")
            cur.execute("FETCH ALL FROM cursor_terapeutas")
            lista_terapeutas = cur.fetchall()

            # Enriquecer con especialidades desde vw_directorio_terapeutas vía SP
            cur.execute("CALL sp_consultar_directorio_terapeutas('cursor_dir_t', NULL)")
            cur.execute("FETCH ALL FROM cursor_dir_t")
            especialidades_por_id = {fila[0]: fila[3] for fila in cur.fetchall()}

    return render_template(
        "terapeutas.html",
        Terapeutas=lista_terapeutas,
        EspecialidadesPorId=especialidades_por_id,
    )


@app.route("/insertarTerapeuta")
@rol_requerido(1)
def insertarTerapeuta():
    return render_template("insertarTerapeuta.html")


@app.route("/registra-terapeuta", methods=["POST"])
@rol_requerido(1)
def registra_terapeuta():
    correo = (request.form.get("correo") or "").strip()
    password_plana = request.form.get("password_hash") or request.form.get("password") or ""
    nombres = (request.form.get("nombres") or "").strip()
    apellido_paterno = (request.form.get("apellido_paterno") or "").strip()
    apellido_materno = (request.form.get("apellido_materno") or "").strip() or None
    cedula = (request.form.get("cedula_profesional") or "").strip()

    if not correo or not password_plana or not nombres or not apellido_paterno or not cedula:
        flash("Por favor completa todos los campos obligatorios.", "error")
        return redirect(url_for("insertarTerapeuta"))

    password_segura = generate_password_hash(password_plana)

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_registrar_terapeuta(%s, %s, %s, %s, %s, %s, NULL, NULL)",
                (correo, password_segura, nombres, apellido_paterno, apellido_materno, cedula),
            )
            id_nuevo, mensaje_bd = cur.fetchone()
        conexion.commit()

    categoria = "success" if id_nuevo is not None else "error"
    flash(mensaje_bd, categoria)
    return redirect(url_for("terapeutas"))


@app.route("/editarTerapeuta/<int:id_terapeuta>", methods=["GET"])
@rol_requerido(1)
def editarTerapeuta(id_terapeuta):
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_obtener_terapeuta_por_id(%s, 'cursor_terapeuta', NULL)", (id_terapeuta,))
            cur.execute("FETCH ALL FROM cursor_terapeuta")
            terapeuta = cur.fetchone()

    if terapeuta is None:
        flash("Terapeuta no encontrado.", "error")
        return redirect(url_for("terapeutas"))

    return render_template("actualizarTerapeuta.html", Terapeuta=terapeuta)


@app.route("/actualizar-terapeuta", methods=["POST"])
@rol_requerido(1)
def actualizar_terapeuta():
    id_terapeuta = request.form.get("id_terapeuta")
    nombres = (request.form.get("nombres") or "").strip()
    apellido_paterno = (request.form.get("apellido_paterno") or "").strip()
    apellido_materno = (request.form.get("apellido_materno") or "").strip() or None
    cedula = (request.form.get("cedula_profesional") or "").strip()

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_actualizar_terapeuta(%s, %s, %s, %s, %s, NULL)",
                (id_terapeuta, nombres, apellido_paterno, apellido_materno, cedula),
            )
            (mensaje_bd,) = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success")
    return redirect(url_for("terapeutas"))


@app.route("/borrarTerapeuta/<int:id_terapeuta>", methods=["POST"])
@rol_requerido(1)
def borrarTerapeuta(id_terapeuta):
    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute("CALL sp_dar_baja_terapeuta(%s, NULL)", (id_terapeuta,))
            (mensaje_bd,) = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success")
    return redirect(url_for("terapeutas"))


# ==============================================================================
# 7. Módulo de Asignaciones (Solo Administrador - Rol 1)
# ==============================================================================
@app.route("/asignaciones")
@rol_requerido(1)
def asignaciones():
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_asignaciones_vigentes('cursor_asignaciones', NULL)")
            cur.execute("FETCH ALL FROM cursor_asignaciones")
            lista_asignaciones = cur.fetchall()
    return render_template("asignaciones.html", Asignaciones=lista_asignaciones)


@app.route("/nuevaAsignacion")
@rol_requerido(1)
def nuevaAsignacion():
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_terapeutas(1, 'cursor_t', NULL)")
            cur.execute("FETCH ALL FROM cursor_t")
            lista_terapeutas = cur.fetchall()

            cur.execute("CALL sp_listar_pacientes_sin_asignar('cursor_p', NULL)")
            cur.execute("FETCH ALL FROM cursor_p")
            lista_pacientes = cur.fetchall()

    return render_template("nuevaAsignacion.html", Terapeutas=lista_terapeutas, Pacientes=lista_pacientes)


@app.route("/registra-asignacion", methods=["POST"])
@rol_requerido(1)
def registra_asignacion():
    id_terapeuta = request.form.get("id_terapeuta")
    id_paciente = request.form.get("id_paciente")
    id_admin = session.get("usuario_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_asignar_terapeuta_paciente(%s, %s, %s, NULL, NULL)",
                (id_terapeuta, id_paciente, id_admin),
            )
            id_asignacion, mensaje_bd = cur.fetchone()
        conexion.commit()

    categoria = "success" if id_asignacion is not None else "error"
    flash(mensaje_bd, categoria)
    return redirect(url_for("asignaciones"))


# ==============================================================================
# 8. Módulo de Agenda y Sesiones (Roles 1, 2 y 3 con alcance por rol y propiedad)
# ==============================================================================
@app.route("/sesiones")
@rol_requerido(1, 2, 3)
def sesiones():
    rol = session.get("usuario_rol")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            if rol == 1:
                cur.execute("CALL sp_consultar_agenda_global('cursor_agenda', NULL)")
            elif rol == 2:
                id_terapeuta = session.get("terapeuta_id")
                cur.execute("CALL sp_consultar_agenda_terapeuta(%s, 'cursor_agenda', NULL)", (id_terapeuta,))
            else:
                id_paciente = session.get("paciente_id")
                cur.execute("CALL sp_consultar_agenda_paciente(%s, 'cursor_agenda', NULL)", (id_paciente,))

            cur.execute("FETCH ALL FROM cursor_agenda")
            agenda = cur.fetchall()

    return render_template("sesiones.html", Agenda=agenda)


@app.route("/nuevaSesion")
@rol_requerido(1, 2)
def nuevaSesion():
    rol = session.get("usuario_rol")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            if rol == 1:
                cur.execute("CALL sp_consultar_asignaciones_vigentes('cursor_asignaciones', NULL)")
            else:
                id_terapeuta = session.get("terapeuta_id")
                cur.execute(
                    "CALL sp_consultar_asignaciones_terapeuta(%s, 'cursor_asignaciones', NULL)",
                    (id_terapeuta,),
                )
            cur.execute("FETCH ALL FROM cursor_asignaciones")
            lista_asignaciones = cur.fetchall()

            cur.execute("CALL sp_obtener_modalidades('cursor_modalidades')")
            cur.execute("FETCH ALL FROM cursor_modalidades")
            modalidades = cur.fetchall()

    return render_template("nuevaSesion.html", Asignaciones=lista_asignaciones, Modalidades=modalidades)


@app.route("/registra-sesion", methods=["POST"])
@rol_requerido(1, 2)
def registra_sesion():
    id_asignacion = request.form.get("id_asignacion")
    id_modalidad = request.form.get("id_modalidad")
    fecha = request.form.get("fecha")
    hora_inicio = request.form.get("hora_inicio")
    hora_fin = request.form.get("hora_fin")

    if hora_inicio and hora_fin and hora_fin <= hora_inicio:
        return render_template(
            "errorAgenda.html",
            mensaje="La hora de fin debe ser posterior a la hora de inicio.",
        )

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            if session.get("usuario_rol") == 2:
                cur.execute(
                    "CALL sp_validar_propiedad_asignacion(%s, %s, NULL, NULL)",
                    (id_asignacion, session.get("terapeuta_id")),
                )
                es_propietario, msg_prop = cur.fetchone()
                if not es_propietario:
                    flash(msg_prop, "error")
                    return redirect(url_for("sesiones"))

            cur.execute(
                "CALL sp_agendar_sesion(%s, %s, %s, %s, %s, NULL, NULL)",
                (id_asignacion, id_modalidad, fecha, hora_inicio, hora_fin),
            )
            id_nuevo, mensaje_bd = cur.fetchone()
        conexion.commit()

    if id_nuevo is None:
        return render_template("errorAgenda.html", mensaje=mensaje_bd)

    flash(mensaje_bd, "success")
    return redirect(url_for("sesiones"))


@app.route("/cancelar-sesion/<int:id_sesion>", methods=["POST"])
@rol_requerido(1, 2)
def cancelar_sesion(id_sesion):
    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            if session.get("usuario_rol") == 2:
                cur.execute(
                    "CALL sp_validar_propiedad_sesion(%s, %s, NULL, NULL)",
                    (id_sesion, session.get("terapeuta_id")),
                )
                tiene_acceso, msg_prop = cur.fetchone()
                if not tiene_acceso:
                    flash(msg_prop, "error")
                    return redirect(url_for("sesiones"))

            cur.execute("CALL sp_cancelar_sesion(%s, NULL)", (id_sesion,))
            (mensaje_bd,) = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success")
    return redirect(url_for("sesiones"))


# ==============================================================================
# 9. Módulo de Alertas Clínicas (Roles 1 y 2 — Vista vw_alertas_activas vía SP)
# ==============================================================================
@app.route("/alertas")
@rol_requerido(1, 2)
def alertas():
    rol = session.get("usuario_rol")
    filtro_terapeuta = None if rol == 1 else session.get("terapeuta_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_alertas_activas(%s, 'cursor_alertas', NULL)", (filtro_terapeuta,))
            cur.execute("FETCH ALL FROM cursor_alertas")
            lista_alertas = cur.fetchall()

    return render_template("alertas.html", Alertas=lista_alertas)


@app.route("/alertas/atender/<int:id_alerta>", methods=["POST"])
@rol_requerido(1, 2)
def atender_alerta(id_alerta):
    rol = session.get("usuario_rol")
    filtro_terapeuta = None if rol == 1 else session.get("terapeuta_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_atender_alerta(%s, %s, NULL, NULL)",
                (id_alerta, filtro_terapeuta),
            )
            atendida, mensaje_bd = cur.fetchone()
        conexion.commit()

    flash(mensaje_bd, "success" if atendida else "error")
    return redirect(url_for("alertas"))


# ==============================================================================
# 10. Módulo de Reportes Avanzados (4 SPs con Tablas Temporales + Vistas vw_*)
# ==============================================================================
@app.route("/reportes")
@rol_requerido(1, 2)
def reportes():
    rol = session.get("usuario_rol")
    filtro_terapeuta = None if rol == 1 else session.get("terapeuta_id")

    if rol == 1:
        vistas_permitidas = [
            ("anonimizados", "Indicadores Anonimizados (SP Temporal)"),
            ("ranking", "Ranking Terapeutas (SP Temporal)"),
            ("planes", "Avance de Planes (SP Temporal)"),
            ("directorio_pacientes", "Directorio Pacientes (vw_directorio_pacientes)"),
            ("directorio_terapeutas", "Directorio Terapeutas (vw_directorio_terapeutas)"),
            ("progreso", "Progreso Clínico (vw_progreso_clinico)"),
            ("instrumentos", "Resultados Escalas (vw_resultados_instrumentos)"),
        ]
        vista_default = "anonimizados"
    else:
        vistas_permitidas = [
            ("evolucion", "Evolución Longitudinal (SP Temporal)"),
            ("planes", "Avance de Mis Planes (SP Temporal)"),
            ("progreso", "Progreso Clínico (vw_progreso_clinico)"),
            ("instrumentos", "Resultados Escalas (vw_resultados_instrumentos)"),
        ]
        vista_default = "evolucion"

    claves_validas = {k for k, _ in vistas_permitidas}
    vista_actual = request.args.get("vista", vista_default)
    if vista_actual not in claves_validas:
        vista_actual = vista_default

    filas = []
    columnas = []
    fuente_bd = ""

    with conectar() as conexion:
        with conexion.cursor() as cur:
            if vista_actual == "anonimizados":
                cur.execute("CALL sp_reporte_indicadores_anonimizados('cursor_rep', NULL)")
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["Rango Etario", "Modalidad", "Pacientes Únicos", "Total Sesiones", "% Completadas", "Promedio Escala"]
                fuente_bd = "SP con Tabla Temporal: sp_reporte_indicadores_anonimizados (sin PII)"
            elif vista_actual == "ranking":
                cur.execute("CALL sp_reporte_ranking_terapeutas('cursor_rep', NULL)")
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["Posición", "Terapeuta", "Cédula", "Especialidades", "Pacientes Activos", "Sesiones", "Completadas", "Canceladas", "% Cumplimiento"]
                fuente_bd = "SP con Tabla Temporal + RANK() OVER: sp_reporte_ranking_terapeutas (sobre vw_directorio_terapeutas)"
            elif vista_actual == "evolucion":
                cur.execute("CALL sp_reporte_evolucion_longitudinal(%s, 'cursor_rep', NULL)", (filtro_terapeuta,))
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["Paciente", "Instrumento", "Dimensión", "Fecha", "Puntuación", "Previa (LAG)", "Cambio (Δ)", "Promedio (AVG OVER)", "Clasificación"]
                fuente_bd = "SP con Tabla Temporal + LAG/AVG OVER: sp_reporte_evolucion_longitudinal (sobre vw_resultados_instrumentos)"
            elif vista_actual == "planes":
                cur.execute("CALL sp_reporte_avance_planes(%s, 'cursor_rep', NULL)", (filtro_terapeuta,))
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["ID Plan", "Paciente", "Terapeuta", "Estado Plan", "Objetivos", "Logrados", "Avance Promedio (%)", "Fecha Inicio"]
                fuente_bd = "SP con Tabla Temporal + CTE: sp_reporte_avance_planes"
            elif vista_actual == "directorio_pacientes":
                cur.execute("CALL sp_consultar_directorio_pacientes('cursor_rep', NULL)")
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["ID", "Nombre Completo", "Teléfono", "Correo", "Estatus", "Fecha Registro"]
                fuente_bd = "Vista vw_directorio_pacientes (vía sp_consultar_directorio_pacientes)"
            elif vista_actual == "directorio_terapeutas":
                cur.execute("CALL sp_consultar_directorio_terapeutas('cursor_rep', NULL)")
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["ID", "Terapeuta", "Cédula Profesional", "Especialidades", "Estatus"]
                fuente_bd = "Vista vw_directorio_terapeutas (vía sp_consultar_directorio_terapeutas)"
            elif vista_actual == "progreso":
                cur.execute("CALL sp_consultar_progreso_clinico(%s, 'cursor_rep', NULL)", (filtro_terapeuta,))
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["Paciente", "Objetivo Terapéutico", "Estado", "Avance Actual (%)", "Última Actualización", "Comentario"]
                fuente_bd = "Vista vw_progreso_clinico (vía sp_consultar_progreso_clinico)"
            elif vista_actual == "instrumentos":
                cur.execute("CALL sp_consultar_resultados_instrumentos(%s, 'cursor_rep', NULL)", (filtro_terapeuta,))
                cur.execute("FETCH ALL FROM cursor_rep")
                filas = cur.fetchall()
                columnas = ["ID Aplicación", "Instrumento", "Paciente", "Dimensión Evaluada", "Puntuación Bruta", "Fecha Respuesta"]
                fuente_bd = "Vista vw_resultados_instrumentos (vía sp_consultar_resultados_instrumentos)"

    return render_template(
        "reportes.html",
        vistas_permitidas=vistas_permitidas,
        vista_actual=vista_actual,
        columnas=columnas,
        filas=filas,
        fuente_bd=fuente_bd,
    )


# ==============================================================================
# 11. Módulo de Auditoría (Solo Administrador - Rol 1 — vw_reporte_auditoria)
# ==============================================================================
@app.route("/auditoria")
@rol_requerido(1)
def auditoria():
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute("CALL sp_consultar_auditoria(100, 'cursor_auditoria', NULL)")
            cur.execute("FETCH ALL FROM cursor_auditoria")
            registros_auditoria = cur.fetchall()

    return render_template("auditoria.html", Auditoria=registros_auditoria)


# ==============================================================================
# 12. Punto de Entrada
# ==============================================================================
if __name__ == "__main__":
    ok, msg = verificar_conexion_bd()
    print(f"[BD] {msg}")
    if not ok:
        raise SystemExit(1)

    host = os.environ.get("FLASK_HOST", "127.0.0.1")
    port = int(os.environ.get("FLASK_PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "false").lower() == "true"
    app.run(host=host, port=port, debug=debug)
