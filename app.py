"""
Sistema de Gestión Clínica (Equipo 01) — Backend Flask + Jinja2 + PostgreSQL (SP exclusivo) + MongoDB Atlas.

Estructura del archivo:
  1. Configuración e Infraestructura (variables de entorno, Flask, conexión BD y auditoría)
  2. Seguridad y Control de Acceso (RBAC y guardia global)
  3. Autenticación (/login, /logout)
  4. Inicio / Dashboard (/)
  5. Módulo de Pacientes (/pacientes, /mis_pacientes, CRUD y baja lógica)
  6. Módulo de Terapeutas (/terapeutas, CRUD y baja lógica)
  7. Módulo de Asignaciones (/asignaciones, vinculación terapeuta-paciente)
  8. Módulo de Agenda y Sesiones (/sesiones, agendar, reprogramar, cancelar, consulta SOAP)
  9. Módulo de Alertas Clínicas (/alertas, atención de alertas — vw_alertas_activas)
 10. Módulo de Reportes Avanzados (/reportes — 4 SPs con tablas temporales y vistas vw_*)
 11. Módulo de Auditoría (/auditoria — vw_reporte_auditoria, Solo Admin)
 12. Módulo de Planes Terapéuticos y Objetivos (/planes, /objetivos)
 13. Módulo de Cuestionarios Psicométricos (/instrumentos — PG + MongoDB Atlas)
 14. Módulo de Bitácoras Emocionales (/bitacoras — Privacidad clínica PG + MongoDB Atlas)
 15. Punto de Entrada (__main__)
"""

from datetime import datetime, timezone
from functools import wraps
import os
import secrets

from dotenv import load_dotenv
from flask import Flask, flash, redirect, render_template, request, session, url_for
import psycopg
from werkzeug.security import check_password_hash, generate_password_hash

import clinica_soap
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
# 8. Módulo de Agenda, Sesiones, Reprogramación y Consulta Clínica (Nota SOAP)
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


@app.route("/sesiones/<int:id_sesion>/reprogramar", methods=["GET", "POST"])
@rol_requerido(1, 2)
def reprogramar_sesion(id_sesion):
    filtro_terapeuta = None if session.get("usuario_rol") == 1 else session.get("terapeuta_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_obtener_detalle_sesion(%s, %s, 'cursor_ses_rep', NULL, NULL)",
                (id_sesion, filtro_terapeuta),
            )
            _, autorizado, msg_det = cur.fetchone()
            cur.execute("FETCH ALL FROM cursor_ses_rep")
            sesion_det = cur.fetchone()

        if not autorizado or sesion_det is None:
            flash(msg_det or "Acceso denegado a la sesión solicitada.", "error")
            return redirect(url_for("sesiones"))

        if request.method == "POST":
            nueva_fecha = request.form.get("fecha")
            nueva_inicio = request.form.get("hora_inicio")
            nueva_fin = request.form.get("hora_fin")

            if nueva_inicio and nueva_fin and nueva_fin <= nueva_inicio:
                flash("La hora de fin debe ser posterior a la hora de inicio.", "error")
                return render_template("reprogramar_sesion.html", sesion=sesion_det)

            with conexion.cursor() as cur:
                establecer_contexto_auditoria(cur)
                cur.execute(
                    "CALL sp_reprogramar_sesion(%s, %s, %s, %s, NULL)",
                    (id_sesion, nueva_fecha, nueva_inicio, nueva_fin),
                )
                (msg_rep,) = cur.fetchone()
            conexion.commit()

            es_error = msg_rep and msg_rep.lower().startswith("error")
            flash(msg_rep, "error" if es_error else "success")
            if es_error:
                return render_template("reprogramar_sesion.html", sesion=sesion_det)
            return redirect(url_for("sesiones"))

    return render_template("reprogramar_sesion.html", sesion=sesion_det)


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


@app.route("/sesiones/<int:id_sesion>/consulta", methods=["GET", "POST"])
@rol_requerido(2)
def consulta_sesion(id_sesion):
    """Flujo completo de consulta: transcripción, generación/edición de Nota SOAP y cierre de sesión (Solo Terapeuta)."""
    id_terapeuta = session.get("terapeuta_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_obtener_detalle_sesion(%s, %s, 'cursor_ses_soap', NULL, NULL)",
                (id_sesion, id_terapeuta),
            )
            _, autorizado, msg_det = cur.fetchone()
            cur.execute("FETCH ALL FROM cursor_ses_soap")
            sesion_det = cur.fetchone()

        if not autorizado or sesion_det is None:
            flash(msg_det or "Acceso denegado: esta sesión no corresponde a tu cartera clínica.", "error")
            return redirect(url_for("sesiones"))

        soap_doc = mongo_db.obtener_resumen_soap_por_sesion(id_sesion)
        historial = mongo_db.listar_historial_ediciones_sesion(id_sesion)

        if request.method == "POST":
            accion = request.form.get("accion", "guardar")
            transcripcion = (request.form.get("transcripcion_texto") or "").strip()

            if accion == "generar":
                generado = clinica_soap.generar_nota_soap_simulada(
                    transcripcion=transcripcion,
                    nombre_paciente=sesion_det[7],
                    modalidad=sesion_det[4],
                    fecha_sesion=str(sesion_det[1]),
                )
                borrador = {
                    "transcripcion_texto": transcripcion,
                    "nota_soap": generado["nota_soap"],
                    "resumen_automatico_simulado": generado["resumen_automatico"],
                    "palabras_clave": generado["palabras_clave"],
                    "version_actual": soap_doc.get("version_actual", 0) if soap_doc else 0,
                }
                flash(
                    "Borrador de Nota SOAP y resumen automático simulado generado. Revísalo y guarda para confirmar.",
                    "success",
                )
                return render_template(
                    "consulta_soap.html",
                    sesion=sesion_det,
                    soap=borrador,
                    historial=historial,
                )

            nota_soap = {
                "subjetivo": (request.form.get("soap_subjetivo") or "").strip(),
                "objetivo": (request.form.get("soap_objetivo") or "").strip(),
                "analisis": (request.form.get("soap_analisis") or "").strip(),
                "plan": (request.form.get("soap_plan") or "").strip(),
            }
            resumen_auto = (request.form.get("resumen_automatico") or "").strip()
            nota_extensa = (request.form.get("nota_extensa_terapeuta") or "").strip()
            motivo_cambio = (request.form.get("motivo_cambio") or "").strip() or "Actualización de consulta clínica"
            _, _, palabras_clave = clinica_soap.extraer_palabras_clave(
                f"{transcripcion} {nota_soap['subjetivo']} {nota_soap['analisis']}"
            )

            if not nota_soap["subjetivo"] or not nota_soap["analisis"] or not nota_soap["plan"]:
                flash("Completa al menos los apartados Subjetivo, Análisis y Plan (o usa Generar Nota SOAP).", "error")
                borrador = {
                    "transcripcion_texto": transcripcion,
                    "nota_soap": nota_soap,
                    "resumen_automatico_simulado": resumen_auto,
                    "palabras_clave": palabras_clave,
                    "version_actual": soap_doc.get("version_actual", 0) if soap_doc else 0,
                }
                return render_template(
                    "consulta_soap.html",
                    sesion=sesion_det,
                    soap=borrador,
                    historial=historial,
                )

            mongo_id, id_ref, msg_coord = mongo_db.guardar_resumen_soap_coordinado(
                conn_pg=conexion,
                id_sesion=id_sesion,
                id_paciente=sesion_det[6],
                id_terapeuta=sesion_det[8],
                fecha_sesion=str(sesion_det[1]),
                transcripcion_texto=transcripcion,
                nota_soap=nota_soap,
                resumen_automatico=resumen_auto,
                palabras_clave=palabras_clave,
                nota_extensa_terapeuta=nota_extensa,
                editado_por_usuario_pg=session.get("usuario_id"),
                motivo_cambio=motivo_cambio,
            )

            if mongo_id is None:
                flash(msg_coord, "error")
                return redirect(url_for("consulta_sesion", id_sesion=id_sesion))

            # Si la sesión seguía Programada, marcarla automáticamente como Completada vía SP
            if sesion_det[5] == "Programada":
                with conexion.cursor() as cur:
                    establecer_contexto_auditoria(cur)
                    cur.execute("CALL sp_completar_sesion(%s, NULL)", (id_sesion,))
                conexion.commit()
                flash("Nota SOAP guardada en MongoDB Atlas, referenciada en PostgreSQL y sesión marcada como Completada.", "success")
            else:
                flash("Nota SOAP actualizada con nueva versión en historial clínico.", "success")

            return redirect(url_for("consulta_sesion", id_sesion=id_sesion))

    return render_template("consulta_soap.html", sesion=sesion_det, soap=soap_doc, historial=historial)


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
# 12. Módulo de Planes Terapéuticos y Objetivos (Terapeuta = Gestión | Paciente = Lectura)
# ==============================================================================
@app.route("/planes")
@rol_requerido(2, 3)
def planes():
    rol = session.get("usuario_rol")
    id_terapeuta = session.get("terapeuta_id") if rol == 2 else None
    id_paciente = session.get("paciente_id") if rol == 3 else None
    mis_asignaciones = []

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_consultar_planes_terapeuticos(%s, %s, 'cursor_planes', NULL)",
                (id_terapeuta, id_paciente),
            )
            cur.execute("FETCH ALL FROM cursor_planes")
            lista_planes = cur.fetchall()

            if rol == 2:
                cur.execute(
                    "CALL sp_consultar_asignaciones_terapeuta(%s, 'cursor_asig_p', NULL)",
                    (id_terapeuta,),
                )
                cur.execute("FETCH ALL FROM cursor_asig_p")
                mis_asignaciones = cur.fetchall()

    return render_template("planes.html", Planes=lista_planes, Asignaciones=mis_asignaciones)


@app.route("/planes/nuevo", methods=["POST"])
@rol_requerido(2)
def crear_plan():
    id_asignacion = request.form.get("id_asignacion")
    fecha_inicio = request.form.get("fecha_inicio") or None
    descripcion = (request.form.get("descripcion_general") or "").strip()

    if not id_asignacion or not descripcion:
        flash("Selecciona un paciente y describe el objetivo general del plan terapéutico.", "error")
        return redirect(url_for("planes"))

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_validar_propiedad_asignacion(%s, %s, NULL, NULL)",
                (id_asignacion, session.get("terapeuta_id")),
            )
            autorizado, msg_prop = cur.fetchone()
            if not autorizado:
                flash(msg_prop, "error")
                return redirect(url_for("planes"))

            cur.execute(
                "CALL sp_crear_plan_terapeutico(%s, %s, %s, NULL, NULL)",
                (id_asignacion, fecha_inicio, descripcion),
            )
            id_nuevo_plan, msg_bd = cur.fetchone()
        conexion.commit()

    if id_nuevo_plan is None:
        flash(msg_bd, "error")
        return redirect(url_for("planes"))

    flash(msg_bd, "success")
    return redirect(url_for("detalle_plan", id_plan=id_nuevo_plan))


@app.route("/planes/<int:id_plan>")
@rol_requerido(2, 3)
def detalle_plan(id_plan):
    rol = session.get("usuario_rol")
    id_terapeuta = session.get("terapeuta_id") if rol == 2 else None
    id_paciente = session.get("paciente_id") if rol == 3 else None

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_obtener_plan_detalle(%s, %s, %s, 'cursor_plan_det', NULL, NULL)",
                (id_plan, id_terapeuta, id_paciente),
            )
            _, autorizado, msg_det = cur.fetchone()
            cur.execute("FETCH ALL FROM cursor_plan_det")
            plan = cur.fetchone()

            if not autorizado or plan is None:
                flash(msg_det or "No tienes acceso a este plan terapéutico.", "error")
                return redirect(url_for("planes"))

            cur.execute("CALL sp_consultar_objetivos_de_plan(%s, 'cursor_objs', NULL)", (id_plan,))
            cur.execute("FETCH ALL FROM cursor_objs")
            objetivos = cur.fetchall()

            historiales = {}
            for obj in objetivos:
                id_obj = obj[0]
                cur.execute("CALL sp_consultar_historial_objetivos(%s, 'cursor_hobj', NULL)", (id_obj,))
                cur.execute("FETCH ALL FROM cursor_hobj")
                historiales[id_obj] = cur.fetchall()

    return render_template("plan_detalle.html", plan=plan, objetivos=objetivos, historiales=historiales)


@app.route("/planes/<int:id_plan>/objetivos/nuevo", methods=["POST"])
@rol_requerido(2)
def crear_objetivo(id_plan):
    nombre = (request.form.get("nombre") or "").strip()
    descripcion = (request.form.get("descripcion") or "").strip()
    fecha_inicio = request.form.get("fecha_inicio") or None
    fecha_meta = request.form.get("fecha_meta") or None

    if not nombre:
        flash("El nombre del objetivo terapéutico es obligatorio.", "error")
        return redirect(url_for("detalle_plan", id_plan=id_plan))

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_obtener_plan_detalle(%s, %s, NULL, 'cursor_val_plan', NULL, NULL)",
                (id_plan, session.get("terapeuta_id")),
            )
            _, autorizado, msg_val = cur.fetchone()
            if not autorizado:
                flash(msg_val, "error")
                return redirect(url_for("planes"))

            cur.execute(
                "CALL sp_crear_objetivo(%s, %s, %s, %s, %s, NULL, NULL)",
                (id_plan, nombre, descripcion, fecha_inicio, fecha_meta),
            )
            id_obj, msg_bd = cur.fetchone()
        conexion.commit()

    flash(msg_bd, "success" if id_obj is not None else "error")
    return redirect(url_for("detalle_plan", id_plan=id_plan))


@app.route("/objetivos/<int:id_objetivo>/avance", methods=["POST"])
@rol_requerido(2)
def registrar_avance_objetivo(id_objetivo):
    porcentaje_raw = request.form.get("porcentaje") or "0"
    comentario = (request.form.get("comentario") or "").strip()

    try:
        porcentaje = float(porcentaje_raw)
        if porcentaje < 0 or porcentaje > 100:
            raise ValueError("Fuera de rango")
    except ValueError:
        flash("El porcentaje de avance debe ser un número entre 0 y 100.", "error")
        return redirect(url_for("planes"))

    with conectar() as conexion:
        with conexion.cursor() as cur:
            establecer_contexto_auditoria(cur)
            cur.execute(
                "CALL sp_validar_propiedad_objetivo(%s, %s, NULL, NULL, NULL)",
                (id_objetivo, session.get("terapeuta_id")),
            )
            autorizado, id_plan, msg_val = cur.fetchone()
            if not autorizado:
                flash(msg_val, "error")
                return redirect(url_for("planes"))

            cur.execute(
                "CALL sp_registrar_avance_objetivo(%s, %s, %s, %s, NULL)",
                (id_objetivo, porcentaje, comentario, session.get("usuario_id")),
            )
            (msg_bd,) = cur.fetchone()
        conexion.commit()

    if porcentaje >= 100:
        flash(f"{msg_bd} (Trigger reactivo: objetivo marcado como Logrado).", "success")
    else:
        flash(msg_bd, "success")
    return redirect(url_for("detalle_plan", id_plan=id_plan))


# ==============================================================================
# 13. Módulo de Cuestionarios Psicométricos Simulados (PostgreSQL + MongoDB Atlas)
# ==============================================================================
@app.route("/instrumentos")
@rol_requerido(2, 3)
def instrumentos():
    rol = session.get("usuario_rol")
    id_terapeuta = session.get("terapeuta_id") if rol == 2 else None
    id_paciente = session.get("paciente_id") if rol == 3 else None
    catalogo_inst = []
    mis_pac = []

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_consultar_aplicaciones_instrumentos(%s, %s, 'cursor_apps', NULL)",
                (id_terapeuta, id_paciente),
            )
            cur.execute("FETCH ALL FROM cursor_apps")
            aplicaciones = cur.fetchall()

            if rol == 2:
                cur.execute("CALL sp_listar_instrumentos_activos('cursor_inst', NULL)")
                cur.execute("FETCH ALL FROM cursor_inst")
                catalogo_inst = cur.fetchall()

                cur.execute("CALL sp_consultar_mis_pacientes(%s, 'cursor_mp_i')", (id_terapeuta,))
                cur.execute("FETCH ALL FROM cursor_mp_i")
                mis_pac = cur.fetchall()

    return render_template(
        "instrumentos.html",
        Aplicaciones=aplicaciones,
        Instrumentos=catalogo_inst,
        MisPacientes=mis_pac,
    )


@app.route("/instrumentos/asignar", methods=["POST"])
@rol_requerido(2)
def asignar_instrumento():
    id_instrumento = request.form.get("id_instrumento")
    id_paciente = request.form.get("id_paciente")

    if not id_instrumento or not id_paciente:
        flash("Selecciona el instrumento y el paciente.", "error")
        return redirect(url_for("instrumentos"))

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_asignar_instrumento(%s, %s, %s, NULL, NULL)",
                (id_instrumento, id_paciente, session.get("terapeuta_id")),
            )
            id_app, msg_bd = cur.fetchone()
        conexion.commit()

    flash(msg_bd, "success" if id_app is not None else "error")
    return redirect(url_for("instrumentos"))


@app.route("/instrumentos/responder/<int:id_aplicacion>", methods=["GET", "POST"])
@rol_requerido(3)
def responder_instrumento(id_aplicacion):
    """El paciente responde un cuestionario dinámico cargado desde MongoDB Atlas."""
    id_paciente = session.get("paciente_id")

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_obtener_aplicacion_detalle(%s, NULL, %s, 'cursor_app_r', NULL, NULL)",
                (id_aplicacion, id_paciente),
            )
            _, autorizado, msg_val = cur.fetchone()
            cur.execute("FETCH ALL FROM cursor_app_r")
            aplicacion = cur.fetchone()

        if not autorizado or aplicacion is None:
            flash(msg_val or "No tienes acceso a este cuestionario.", "error")
            return redirect(url_for("instrumentos"))

        if aplicacion[7] == "Completada":
            flash("Este cuestionario ya fue respondido anteriormente.", "success")
            return redirect(url_for("detalle_instrumento", id_aplicacion=id_aplicacion))

        plantilla = mongo_db.obtener_plantilla_instrumento(aplicacion[1])
        if not plantilla:
            flash("No se encontró la plantilla del cuestionario en MongoDB.", "error")
            return redirect(url_for("instrumentos"))

        if request.method == "POST":
            escala_max = int(plantilla.get("escala", {}).get("max", 3)) or 3
            respuestas_items = []
            respuesta_abierta = ""
            sumas_dim = {}
            conteos_dim = {}

            for preg in plantilla.get("preguntas", []):
                cod = preg["codigo"]
                id_dim = int(preg["id_dimension_pg"])
                if preg.get("tipo") == "abierta":
                    respuesta_abierta = (request.form.get(f"preg_{cod}") or "").strip()
                    respuestas_items.append({"codigo": cod, "texto": preg["texto"], "respuesta": respuesta_abierta})
                else:
                    val = int(request.form.get(f"preg_{cod}", "0"))
                    val = max(0, min(escala_max, val))
                    respuestas_items.append({"codigo": cod, "texto": preg["texto"], "valor": val, "id_dimension_pg": id_dim})
                    sumas_dim[id_dim] = sumas_dim.get(id_dim, 0) + val
                    conteos_dim[id_dim] = conteos_dim.get(id_dim, 0) + 1

            # Normalizar cada dimensión a una escala clínica comparable (0-20) para trazabilidad y umbrales (>= 15 alerta)
            puntuaciones_dim = []
            for id_dim, suma in sorted(sumas_dim.items()):
                max_posible = conteos_dim[id_dim] * escala_max
                puntaje_norm = round((suma / max_posible) * 20.0, 2) if max_posible > 0 else 0.0
                puntuaciones_dim.append({"id_dimension_pg": id_dim, "puntuacion": puntaje_norm})

            max_punt = max((d["puntuacion"] for d in puntuaciones_dim), default=0.0)
            severidad = "Elevada (Alerta)" if max_punt >= 15 else ("Moderada" if max_punt >= 10 else "Leve/Estable")

            doc_respuesta = {
                "id_instrumento_pg": aplicacion[1],
                "instrumento_nombre": aplicacion[2],
                "id_paciente_pg": aplicacion[3],
                "id_terapeuta_pg": aplicacion[5],
                "fecha_respuesta": datetime.now(timezone.utc),
                "respuestas_items": respuestas_items,
                "puntuaciones_por_dimension": puntuaciones_dim,
                "puntuacion_maxima_dimension": max_punt,
                "nivel_severidad": severidad,
                "respuesta_abierta": respuesta_abierta,
            }

            mongo_id, msg_coord = mongo_db.guardar_respuesta_instrumento_coordinada(
                conexion, id_aplicacion, doc_respuesta
            )
            if not mongo_id:
                flash(msg_coord, "error")
                return redirect(url_for("instrumentos"))

            # Guardar puntuaciones numéricas por dimensión en PostgreSQL (dispara trigger de alerta si >= 15)
            with conexion.cursor() as cur:
                for dim in puntuaciones_dim:
                    cur.execute(
                        "CALL sp_registrar_resultado_dimension(%s, %s, %s, NULL, NULL)",
                        (id_aplicacion, dim["id_dimension_pg"], dim["puntuacion"]),
                    )
            conexion.commit()

            flash("¡Gracias! Tus respuestas se guardaron correctamente y ya están disponibles para tu terapeuta.", "success")
            return redirect(url_for("detalle_instrumento", id_aplicacion=id_aplicacion))

    return render_template("responder_instrumento.html", aplicacion=aplicacion, plantilla=plantilla)


@app.route("/instrumentos/detalle/<int:id_aplicacion>")
@rol_requerido(2, 3)
def detalle_instrumento(id_aplicacion):
    rol = session.get("usuario_rol")
    id_terapeuta = session.get("terapeuta_id") if rol == 2 else None
    id_paciente = session.get("paciente_id") if rol == 3 else None

    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_obtener_aplicacion_detalle(%s, %s, %s, 'cursor_app_d', NULL, NULL)",
                (id_aplicacion, id_terapeuta, id_paciente),
            )
            _, autorizado, msg_val = cur.fetchone()
            cur.execute("FETCH ALL FROM cursor_app_d")
            aplicacion = cur.fetchone()

            if not autorizado or aplicacion is None:
                flash(msg_val or "No tienes acceso a este resultado.", "error")
                return redirect(url_for("instrumentos"))

            cur.execute("CALL sp_listar_resultados_de_aplicacion(%s, 'cursor_res_d', NULL)", (id_aplicacion,))
            cur.execute("FETCH ALL FROM cursor_res_d")
            resultados_pg = cur.fetchall()

    doc_mongo = None
    if aplicacion[8]:
        doc_mongo = mongo_db.obtener_documento_por_id(mongo_db.COLECCION_CUESTIONARIOS, aplicacion[8])

    return render_template(
        "instrumento_detalle.html",
        aplicacion=aplicacion,
        resultados_pg=resultados_pg,
        doc_mongo=doc_mongo,
    )


# ==============================================================================
# 14. Módulo de Bitácoras Emocionales (Solo Paciente dueño y Terapeuta asignado)
#     NOTA DE PRIVACIDAD (R4): El Administrador (Rol 1) NO tiene acceso.
# ==============================================================================
@app.route("/bitacoras")
@rol_requerido(3)
def bitacoras():
    id_paciente = session.get("paciente_id")
    entradas = mongo_db.listar_bitacoras_paciente(id_paciente, limite=50)
    return render_template(
        "bitacoras.html",
        entradas=entradas,
        nombre_paciente=session.get("usuario_correo"),
        puede_crear=True,
    )


@app.route("/bitacoras/nueva", methods=["POST"])
@rol_requerido(3)
def nueva_bitacora():
    id_paciente = session.get("paciente_id")
    estado_animo = (request.form.get("estado_animo") or "Neutral").strip()
    intensidad = int(request.form.get("intensidad") or 5)
    energia = int(request.form.get("energia") or 5)
    sueno_horas = float(request.form.get("sueno_horas") or 7.0)
    detonantes_raw = (request.form.get("detonantes") or "").strip()
    estrategias_raw = (request.form.get("estrategias_usadas") or "").strip()
    pensamientos = (request.form.get("pensamientos") or "").strip()
    notas_libres = (request.form.get("notas_libres") or "").strip()

    detonantes = [x.strip() for x in detonantes_raw.split(",") if x.strip()]
    estrategias = [x.strip() for x in estrategias_raw.split(",") if x.strip()]

    with conectar() as conexion:
        mongo_id, id_ref, msg = mongo_db.guardar_bitacora_coordinada(
            conexion,
            id_paciente,
            {
                "fecha_registro": datetime.now(timezone.utc),
                "estado_animo": estado_animo,
                "intensidad": max(1, min(10, intensidad)),
                "energia": max(1, min(10, energia)),
                "sueno_horas": max(0.0, min(24.0, sueno_horas)),
                "detonantes": detonantes,
                "pensamientos": pensamientos,
                "estrategias_usadas": estrategias,
                "notas_libres": notas_libres,
                "etiquetas": [estado_animo.lower()],
            },
        )

    if mongo_id:
        flash("Entrada registrada en tu bitácora emocional (MongoDB Atlas + referencia en PostgreSQL).", "success")
    else:
        flash(msg, "error")
    return redirect(url_for("bitacoras"))


@app.route("/bitacoras/paciente/<int:id_paciente>")
@rol_requerido(2)
def bitacoras_paciente(id_paciente):
    """Permite al terapeuta consultar la bitácora emocional SOLO de sus pacientes asignados."""
    with conectar() as conexion:
        with conexion.cursor() as cur:
            cur.execute(
                "CALL sp_validar_propiedad_paciente(%s, %s, NULL, NULL, NULL)",
                (id_paciente, session.get("terapeuta_id")),
            )
            autorizado, nombre_paciente, msg_val = cur.fetchone()

    if not autorizado:
        flash(msg_val, "error")
        return redirect(url_for("mis_pacientes"))

    entradas = mongo_db.listar_bitacoras_paciente(id_paciente, limite=50)
    return render_template(
        "bitacoras.html",
        entradas=entradas,
        nombre_paciente=nombre_paciente,
        puede_crear=False,
    )


# ==============================================================================
# 15. Punto de Entrada
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
