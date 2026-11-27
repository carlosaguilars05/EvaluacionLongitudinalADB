-- ============================================================================
-- Fase 2: Stored Procedures de seguridad, verificación de conexión, RBAC y
-- migración de contraseñas a hashes seguros (Werkzeug).
-- ============================================================================

-- 1. Verificación real de conexión a PostgreSQL (reemplaza print() ciego en app.py)
CREATE OR REPLACE PROCEDURE public.sp_verificar_conexion(
    OUT p_ok boolean,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    p_ok := TRUE;
    p_mensaje := 'Conexión verificada correctamente con PostgreSQL (' || current_database() || ').';
EXCEPTION
    WHEN OTHERS THEN
        p_ok := FALSE;
        p_mensaje := 'Error al verificar conexión: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_verificar_conexion(OUT p_ok boolean, OUT p_mensaje character varying) OWNER TO usuario;

-- 2. Registrar fecha/hora del último acceso en login exitoso
CREATE OR REPLACE PROCEDURE public.sp_registrar_acceso_usuario(
    IN p_id_usuario integer,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE usuario
    SET ultimo_acceso = CURRENT_TIMESTAMP
    WHERE id_usuario = p_id_usuario;

    p_mensaje := 'Último acceso actualizado.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al actualizar último acceso: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_registrar_acceso_usuario(IN p_id_usuario integer, OUT p_mensaje character varying) OWNER TO usuario;

-- 3. Listar usuarios para migración segura de contraseñas semilla a hash Werkzeug
CREATE OR REPLACE PROCEDURE public.sp_listar_usuarios_para_migracion(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_usuario, correo, password_hash
        FROM usuario
        ORDER BY id_usuario ASC;

    p_mensaje := 'Usuarios listados para migración de hashes.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar usuarios: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_listar_usuarios_para_migracion(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

-- 4. Actualizar hash de contraseña de un usuario (vía SP exclusivo)
CREATE OR REPLACE PROCEDURE public.sp_actualizar_password_usuario(
    IN p_id_usuario integer,
    IN p_password_hash character varying,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE usuario
    SET password_hash = p_password_hash
    WHERE id_usuario = p_id_usuario;

    p_mensaje := 'Contraseña actualizada correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al actualizar contraseña: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_actualizar_password_usuario(IN p_id_usuario integer, IN p_password_hash character varying, OUT p_mensaje character varying) OWNER TO usuario;

-- 5. Restaurar bloque EXCEPTION en sp_consultar_agenda_paciente
CREATE OR REPLACE PROCEDURE public.sp_consultar_agenda_paciente(
    IN p_id_paciente integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT v.id_sesion, v.fecha, v.hora_inicio, v.hora_fin, v.modalidad, v.estado_sesion, v.terapeuta, v.paciente
        FROM vw_agenda_global v
        JOIN sesion s ON v.id_sesion = s.id_sesion
        JOIN asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        WHERE a.id_paciente = p_id_paciente
        ORDER BY v.fecha DESC, v.hora_inicio DESC;

    p_mensaje := 'Agenda del paciente recuperada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar agenda del paciente: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_consultar_agenda_paciente(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

-- 6. Consultar únicamente las asignaciones vigentes del terapeuta autenticado
CREATE OR REPLACE PROCEDURE public.sp_consultar_asignaciones_terapeuta(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT v.id_asignacion, v.terapeuta_encargado, v.paciente_asignado, v.fecha_inicio
        FROM vw_asignaciones_vigentes v
        JOIN asignacion_terapeuta_paciente a ON v.id_asignacion = a.id_asignacion
        WHERE a.id_terapeuta = p_id_terapeuta
          AND a.id_estado_asignacion = 1
        ORDER BY v.fecha_inicio DESC;

    p_mensaje := 'Asignaciones del terapeuta recuperadas exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar asignaciones del terapeuta: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_consultar_asignaciones_terapeuta(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

-- 7. Validar propiedad de asignación para un terapeuta (RBAC por propiedad)
CREATE OR REPLACE PROCEDURE public.sp_validar_propiedad_asignacion(
    IN p_id_asignacion integer,
    IN p_id_terapeuta integer,
    OUT p_es_propietario boolean,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe integer;
BEGIN
    SELECT COUNT(*) INTO v_existe
    FROM asignacion_terapeuta_paciente
    WHERE id_asignacion = p_id_asignacion
      AND id_terapeuta = p_id_terapeuta
      AND id_estado_asignacion = 1;

    IF v_existe > 0 THEN
        p_es_propietario := TRUE;
        p_mensaje := 'Asignación autorizada para el terapeuta.';
    ELSE
        p_es_propietario := FALSE;
        p_mensaje := 'Acceso denegado: la asignación no corresponde al terapeuta autenticado.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_es_propietario := FALSE;
        p_mensaje := 'Error al validar propiedad de asignación: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_validar_propiedad_asignacion(IN p_id_asignacion integer, IN p_id_terapeuta integer, OUT p_es_propietario boolean, OUT p_mensaje character varying) OWNER TO usuario;

-- 8. Validar propiedad de sesión para un terapeuta antes de cancelar/modificar
CREATE OR REPLACE PROCEDURE public.sp_validar_propiedad_sesion(
    IN p_id_sesion integer,
    IN p_id_terapeuta integer,
    OUT p_tiene_acceso boolean,
    OUT p_mensaje character varying
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_existe integer;
BEGIN
    SELECT COUNT(*) INTO v_existe
    FROM sesion s
    JOIN asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
    WHERE s.id_sesion = p_id_sesion
      AND a.id_terapeuta = p_id_terapeuta;

    IF v_existe > 0 THEN
        p_tiene_acceso := TRUE;
        p_mensaje := 'Sesión autorizada para el terapeuta.';
    ELSE
        p_tiene_acceso := FALSE;
        p_mensaje := 'Acceso denegado: la sesión no pertenece a los pacientes del terapeuta.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_tiene_acceso := FALSE;
        p_mensaje := 'Error al validar propiedad de sesión: ' || SQLERRM;
END;
$$;
ALTER PROCEDURE public.sp_validar_propiedad_sesion(IN p_id_sesion integer, IN p_id_terapeuta integer, OUT p_tiene_acceso boolean, OUT p_mensaje character varying) OWNER TO usuario;

-- 9. Mejorar métricas del dashboard para reflejar solo registros activos
CREATE OR REPLACE PROCEDURE public.sp_consultar_metricas_dashboard(
    OUT p_total_pacientes integer,
    OUT p_total_terapeutas integer,
    OUT p_total_asignaciones integer,
    OUT p_citas_hoy integer
)
LANGUAGE plpgsql
AS $$
BEGIN
    SELECT COUNT(*) INTO p_total_pacientes
    FROM paciente
    WHERE id_estado_paciente = 1;

    SELECT COUNT(*) INTO p_total_terapeutas
    FROM terapeuta
    WHERE id_estado_terapeuta = 1;

    SELECT COUNT(*) INTO p_total_asignaciones
    FROM asignacion_terapeuta_paciente
    WHERE id_estado_asignacion = 1;

    SELECT COUNT(*) INTO p_citas_hoy
    FROM sesion
    WHERE fecha = CURRENT_DATE
      AND id_estado_sesion <> 3;
EXCEPTION
    WHEN OTHERS THEN
        p_total_pacientes := 0;
        p_total_terapeutas := 0;
        p_total_asignaciones := 0;
        p_citas_hoy := 0;
END;
$$;
ALTER PROCEDURE public.sp_consultar_metricas_dashboard(OUT p_total_pacientes integer, OUT p_total_terapeutas integer, OUT p_total_asignaciones integer, OUT p_citas_hoy integer) OWNER TO usuario;
