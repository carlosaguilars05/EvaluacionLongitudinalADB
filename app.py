from flask import Flask, request, render_template, redirect, url_for, session
import psycopg

app = Flask(__name__)
app.secret_key = 'clave_secreta_clinica'

# Configuracion de base de datos
DB_HOST = 'localhost'
DB_USER = 'usuario'
DB_PASSWORD = ''
DB_NAME = 'BD'

print("Aplicacion conectada a la Base de Datos")

def conectar():
    return psycopg.connect(
        host = DB_HOST,
        dbname = DB_NAME,
        user = DB_USER,
        password = DB_PASSWORD
    )

@app.before_request
def proteger_rutas():
    # Rutas que NO requieren estar logueado (login y los archivos CSS)
    rutas_publicas = ['login', 'static']
    
    # Si la ruta que piden no es pública y no hay sesión activa... ¡Para afuera!
    if request.endpoint not in rutas_publicas and 'usuario_id' not in session:
        return redirect(url_for('login'))

# Landing page
@app.route('/')
def principal():
    rol = session.get('usuario_rol')
    
    # Si es Terapeuta (2) o Paciente (3), los mandamos directo a su agenda
    if rol in [2, 3]:
        return redirect(url_for('sesiones'))
        
    # Si es Administrador (1), le calculamos y mostramos el Dashboard
    conexion = conectar()
    cur = conexion.cursor()
    
    cur.execute("CALL SP_Consultar_Metricas_Dashboard(NULL, NULL, NULL, NULL)")
    resultado = cur.fetchone()
    
    conexion.commit()
    cur.close()
    conexion.close()
    
    metricas = {
        'pacientes': resultado[0],
        'terapeutas': resultado[1],
        'asignaciones': resultado[2],
        'citas_hoy': resultado[3]
    }
    
    return render_template('index.html', metricas=metricas)

# Obtener pacientes
@app.route('/pacientes')
def pacientes():

    if session.get('usuario_rol') != 1:
        return redirect(url_for('sesiones'))
    conexion = conectar()
    cur = conexion.cursor()

    # Ejecutamos el Stored Procedure (1 = Activos)
    cur.execute("CALL SP_Consultar_Pacientes(1, 'cursor_pacientes', NULL)")

    # Recuperamos los datos con el refcursor
    cur.execute("FETCH ALL FROM cursor_pacientes")
    Pacientes = cur.fetchall()

    cur.close()
    conexion.close()

    return render_template('registros.html', Pacientes = Pacientes)

# Vista formulario insertar paciente
@app.route('/insertar')
def insertar():
    return render_template('insertar.html')

# Guardar nuevo paciente
@app.route('/registra', methods=['POST'])
def registra():
    correo = request.form.get('correo')
    password_hash = request.form.get('password_hash')
    nombres = request.form.get('nombres')
    apellido_paterno = request.form.get('apellido_paterno')
    apellido_materno = request.form.get('apellido_materno') or None
    fecha_n = request.form.get('fecha_nacimiento')
    sexo = request.form.get('sexo') or None
    tel = request.form.get('telefono') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute(
        "CALL SP_Registrar_Paciente(%s, %s, %s, %s, %s, %s, %s, %s, NULL, NULL)",
        (correo, password_hash, nombres, apellido_paterno, apellido_materno, fecha_n, sexo, tel)
    )
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('pacientes'))

# Vista formulario editar paciente
@app.route('/editar/<int:id_paciente>', methods=['GET'])
def editar(id_paciente):
    conexion = conectar()
    cur = conexion.cursor()
    id_paciente = int(id_paciente)

    cur.execute("CALL SP_Obtener_Paciente_Por_ID(%s, 'cursor_paciente', NULL)", (id_paciente,))
    cur.execute("FETCH ALL FROM cursor_paciente")
    Paciente = cur.fetchone()

    cur.close()
    conexion.close()
    return render_template('actualizar.html', Paciente = Paciente)

# Guardar cambios del paciente
@app.route('/actualizar', methods=['POST'])
def actualizar():
    id_paciente = request.form.get('id_paciente')
    tel = request.form.get('telefono') or None
    nombres = request.form.get('nombres')
    apellido_paterno = request.form.get('apellido_paterno')
    apellido_materno = request.form.get('apellido_materno') or None

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute(
        """
        CALL SP_Actualizar_Paciente(
            %s, %s, %s, %s, %s, NULL
        )
        """,
        (id_paciente, tel, nombres, apellido_paterno, apellido_materno)
    )
    conexion.commit()
    cur.close()
    conexion.close()
    return redirect(url_for('pacientes'))

# Baja lógica de paciente
@app.route('/borrar/<int:id_paciente>', methods=['POST'])
def borrar(id_paciente):
    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL SP_Dar_Baja_Paciente(%s, NULL)", (id_paciente,))
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('pacientes'))

# Obtener terapeutas activos
@app.route('/terapeutas')
def terapeutas():
    if session.get('usuario_rol') != 1:
        return redirect(url_for('sesiones'))
    conexion = conectar()
    cur = conexion.cursor()

    # Ejecutamos el Stored Procedure (1 = Activos)
    cur.execute("CALL SP_Consultar_Terapeutas(1, 'cursor_terapeutas', NULL)")

    # Recuperamos los datos con el refcursor
    cur.execute("FETCH ALL FROM cursor_terapeutas")
    Terapeutas = cur.fetchall()

    cur.close()
    conexion.close()

    return render_template('terapeutas.html', Terapeutas = Terapeutas)

# Vista formulario insertar terapeuta
@app.route('/insertarTerapeuta')
def insertarTerapeuta():
    return render_template('insertarTerapeuta.html')

# Guardar nuevo terapeuta
@app.route('/registra-terapeuta', methods=['POST'])
def registra_terapeuta():
    correo = request.form.get('correo')
    password_hash = request.form.get('password_hash')
    nombres = request.form.get('nombres')
    apellido_paterno = request.form.get('apellido_paterno')
    apellido_materno = request.form.get('apellido_materno') or None
    cedula = request.form.get('cedula_profesional')

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute(
        "CALL SP_Registrar_Terapeuta(%s, %s, %s, %s, %s, %s, NULL, NULL)",
        (correo, password_hash, nombres, apellido_paterno, apellido_materno, cedula)
    )
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('terapeutas'))

# Vista formulario editar terapeuta
@app.route('/editarTerapeuta/<int:id_terapeuta>', methods=['GET'])
def editarTerapeuta(id_terapeuta):
    conexion = conectar()
    cur = conexion.cursor()
    id_terapeuta = int(id_terapeuta)

    cur.execute("CALL SP_Obtener_Terapeuta_Por_ID(%s, 'cursor_terapeuta', NULL)", (id_terapeuta,))
    cur.execute("FETCH ALL FROM cursor_terapeuta")
    Terapeuta = cur.fetchone()

    cur.close()
    conexion.close()
    return render_template('actualizarTerapeuta.html', Terapeuta = Terapeuta)

# Guardar cambios del terapeuta
@app.route('/actualizar-terapeuta', methods=['POST'])
def actualizar_terapeuta():
    id_terapeuta = request.form.get('id_terapeuta')
    nombres = request.form.get('nombres')
    apellido_paterno = request.form.get('apellido_paterno')
    apellido_materno = request.form.get('apellido_materno') or None
    cedula = request.form.get('cedula_profesional')

    conexion = conectar()
    cur = conexion.cursor()
    cur.execute(
        """
        CALL SP_Actualizar_Terapeuta(
            %s, %s, %s, %s, %s, NULL
        )
        """,
        (id_terapeuta, nombres, apellido_paterno, apellido_materno, cedula)
    )
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('terapeutas'))

# Baja lógica de terapeuta
@app.route('/borrarTerapeuta/<int:id_terapeuta>', methods=['POST'])
def borrarTerapeuta(id_terapeuta):
    conexion = conectar()
    cur = conexion.cursor()
    cur.execute("CALL SP_Dar_Baja_Terapeuta(%s, NULL)", (id_terapeuta,))
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('terapeutas'))

# Listar las asignaciones activas
@app.route('/asignaciones')
def asignaciones():
    if session.get('usuario_rol') != 1:
        return redirect(url_for('sesiones'))
    conexion = conectar()
    cur = conexion.cursor()

    cur.execute("CALL SP_Consultar_Asignaciones_Vigentes('cursor_asignaciones', NULL)")
    cur.execute("FETCH ALL FROM cursor_asignaciones")
    Asignaciones = cur.fetchall()

    cur.close()
    conexion.close()
    return render_template('asignaciones.html', Asignaciones=Asignaciones)

# Vista formulario para crear una nueva asignación
@app.route('/nuevaAsignacion')
def nuevaAsignacion():
    conexion = conectar()
    cur = conexion.cursor()

    # 1. Obtener terapeutas activos (estado = 1) para el dropdown
    cur.execute("CALL SP_Consultar_Terapeutas(1, 'cursor_t', NULL)")
    cur.execute("FETCH ALL FROM cursor_t")
    Terapeutas = cur.fetchall()

    # 2. Obtener EXCLUSIVAMENTE pacientes que no tienen terapeuta
    cur.execute("CALL sp_listar_pacientes_sin_asignar('cursor_p', NULL)")
    cur.execute("FETCH ALL FROM cursor_p")
    Pacientes = cur.fetchall()

    cur.close()
    conexion.close()
    return render_template('nuevaAsignacion.html', Terapeutas=Terapeutas, Pacientes=Pacientes)

# Guardar la asignación en la base de datos
@app.route('/registra-asignacion', methods=['POST'])
def registra_asignacion():
    id_terapeuta = request.form.get('id_terapeuta')
    id_paciente = request.form.get('id_paciente')
    id_admin = 1 # ID temporal simulando al usuario Administrador que hace la acción

    conexion = conectar()
    cur = conexion.cursor()
    
    # El SP requiere 3 IN (terapeuta, paciente, asignado_por) y 2 OUT (id_nuevo, mensaje)
    cur.execute(
        "CALL sp_asignar_terapeuta_paciente(%s, %s, %s, NULL, NULL)",
        (id_terapeuta, id_paciente, id_admin)
    )
    conexion.commit()
    cur.close()
    conexion.close()

    return redirect(url_for('asignaciones'))

# Listar todas las sesiones agendadas
@app.route('/sesiones')
def sesiones():
    # CANDADO 1: Si alguien intenta entrar sin iniciar sesión, lo regresamos al login
    if 'usuario_rol' not in session:
        return redirect(url_for('login'))
        
    conexion = conectar()
    cur = conexion.cursor()

    rol = session.get('usuario_rol')

    # Evaluamos qué cursor abrir según el rol
    if rol == 1:
        cur.execute("CALL SP_Consultar_Agenda_Global('cursor_agenda', NULL)")
    elif rol == 2:
        id_terapeuta = session.get('terapeuta_id')
        cur.execute("CALL SP_Consultar_Agenda_Terapeuta(%s, 'cursor_agenda', NULL)", (id_terapeuta,))
    elif rol == 3:
        id_paciente = session.get('paciente_id')
        cur.execute("CALL SP_Consultar_Agenda_Paciente(%s, 'cursor_agenda', NULL)", (id_paciente,))
    
    # Como ya estamos seguros de que el CALL se ejecutó, extraemos los datos
    cur.execute("FETCH ALL FROM cursor_agenda")
    Agenda = cur.fetchall()

    cur.close()
    conexion.close()
    return render_template('sesiones.html', Agenda=Agenda)

# Formulario para agendar una sesión
@app.route('/nuevaSesion')
def nuevaSesion():
    conexion = conectar()
    cur = conexion.cursor()

    # 1. Obtener las Asignaciones Vigentes (Terapeuta-Paciente)
    cur.execute("CALL SP_Consultar_Asignaciones_Vigentes('cursor_asignaciones', NULL)")
    cur.execute("FETCH ALL FROM cursor_asignaciones")
    Asignaciones = cur.fetchall()

    # 2. Obtener las modalidades de sesión
    cur.execute("CALL SP_Obtener_Modalidades('cursor_modalidades')")
    cur.execute("FETCH ALL FROM cursor_modalidades")
    Modalidades = cur.fetchall()

    cur.close()
    conexion.close()
    return render_template('nuevaSesion.html', Asignaciones=Asignaciones, Modalidades=Modalidades)

# Guardar la nueva sesión
@app.route('/registra-sesion', methods=['POST'])
def registra_sesion():
    id_asignacion = request.form.get('id_asignacion')
    id_modalidad = request.form.get('id_modalidad')
    fecha = request.form.get('fecha')
    hora_inicio = request.form.get('hora_inicio')
    hora_fin = request.form.get('hora_fin')

    conexion = conectar()
    cur = conexion.cursor()
    
    cur.execute(
        "CALL SP_Agendar_Sesion(%s, %s, %s, %s, %s, NULL, NULL)",
        (id_asignacion, id_modalidad, fecha, hora_inicio, hora_fin)
    )
    
    # Leemos la respuesta de los parámetros OUT (p_id_nueva_sesion, p_mensaje)
    resultado = cur.fetchone() 
    conexion.commit()
    cur.close()
    conexion.close()

    id_nuevo = resultado[0]
    mensaje_bd = resultado[1]

    # Validamos si la base de datos bloqueó el registro por empalme
    if id_nuevo is None:
        # Hubo un choque de horario. Lo mandamos a la PANTALLA DE ERROR
        return render_template('errorAgenda.html', mensaje=mensaje_bd)
    else:
        # Se agendó bien. Lo mandamos de regreso al calendario
        return redirect(url_for('sesiones'))

# Cancelar una sesión agendada (Baja lógica)
@app.route('/cancelar-sesion/<int:id_sesion>', methods=['POST'])
def cancelar_sesion(id_sesion):
    conexion = conectar()
    cur = conexion.cursor()
    
    # El SP requiere 1 IN y 1 OUT
    cur.execute("CALL SP_Cancelar_Sesion(%s, NULL)", (id_sesion,))
    conexion.commit()
    
    cur.close()
    conexion.close()

    return redirect(url_for('sesiones'))

@app.route('/mis_pacientes')
def mis_pacientes():
    # Candado de seguridad: Solo el Rol 2 (Terapeuta) puede entrar
    if session.get('usuario_rol') != 2:
        flash('Acceso denegado. Esta vista es exclusiva para el terapeuta.', 'error')
        return redirect(url_for('sesiones'))

    id_terapeuta = session.get('terapeuta_id')

    conexion = conectar()
    cur = conexion.cursor()

    # Ejecutamos el SP enviando el ID del terapeuta logueado
    cur.execute("CALL SP_Consultar_Mis_Pacientes(%s, 'cursor_mis_pacientes')", (id_terapeuta,))
    cur.execute("FETCH ALL FROM cursor_mis_pacientes")
    mis_pacientes = cur.fetchall()

    cur.close()
    conexion.close()

    return render_template('misPacientes.html', pacientes=mis_pacientes)

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        correo = request.form.get('correo')
        password_ingresada = request.form.get('password')

        conexion = conectar()
        cur = conexion.cursor()
        
        # Consultamos a PostgreSQL
        cur.execute("CALL SP_Consultar_Usuario_Login(%s, NULL, NULL, NULL, NULL)", (correo,))
        resultado = cur.fetchone()

        id_usuario = resultado[0]
        id_rol = resultado[1]
        password_bd = resultado[2]
        mensaje_bd = resultado[3]

        if id_usuario is not None:
            # Validamos si la contraseña coincide
            if password_ingresada == password_bd:
                # ¡LOGIN EXITOSO! Guardamos los datos en la credencial temporal de Flask
                session['usuario_id'] = id_usuario
                session['usuario_rol'] = id_rol
                session['usuario_correo'] = correo
                
                # Si es terapeuta, buscamos su ID clínico usando el Procedimiento Almacenado
                if id_rol == 2:
                    cur.execute("CALL SP_Consultar_Terapeuta_Usuario(%s, NULL)", (id_usuario,))
                    datos_terapeuta = cur.fetchone()
                    
                    if datos_terapeuta and datos_terapeuta[0] is not None:
                        session['terapeuta_id'] = datos_terapeuta[0]
                
                elif id_rol == 3:
                    cur.execute("CALL SP_Consultar_Paciente_Usuario(%s, NULL)", (id_usuario,))
                    datos_paciente = cur.fetchone()
                    
                    if datos_paciente and datos_paciente[0] is not None:
                        session['paciente_id'] = datos_paciente[0]

                # Cerramos conexión después de obtener todos los datos
                conexion.commit()
                cur.close()
                conexion.close()
                return redirect(url_for('principal'))
            else:
                flash('Contraseña incorrecta.', 'error')
        else:
            flash(mensaje_bd, 'error') # Correo no existe

        # Aseguramos el cierre de conexiones si falla el login
        conexion.commit()
        cur.close()
        conexion.close()

    return render_template('login.html')

@app.route('/logout')
def logout():
    session.clear() # Destruimos la sesión temporal
    return redirect(url_for('login'))


