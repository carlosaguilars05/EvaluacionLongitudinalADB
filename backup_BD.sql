--
-- PostgreSQL database dump
--

\restrict eAgh38gE6xsFTLfAnP3ArlknTsrz3MJqY2Iu65H9y5Rl3X3MQXKSYL8xD9FC51r

-- Dumped from database version 16.14
-- Dumped by pg_dump version 16.14

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: sp_actualizar_paciente(integer, character varying, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_actualizar_paciente(IN p_id_paciente integer, IN p_telefono character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE paciente
    SET telefono = p_telefono, nombre = p_nombre, 
        apellido_paterno = p_ap_pat, apellido_materno = p_ap_mat
    WHERE id_paciente = p_id_paciente;
    
    p_mensaje := 'Datos del paciente actualizados correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al actualizar paciente: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_actualizar_paciente(IN p_id_paciente integer, IN p_telefono character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_actualizar_terapeuta(integer, character varying, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_actualizar_terapeuta(IN p_id_terapeuta integer, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_cedula character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE terapeuta
    SET nombre = p_nombre, apellido_paterno = p_ap_pat, 
        apellido_materno = p_ap_mat, cedula_profesional = p_cedula
    WHERE id_terapeuta = p_id_terapeuta;
    
    p_mensaje := 'Datos del terapeuta actualizados correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al actualizar terapeuta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_actualizar_terapeuta(IN p_id_terapeuta integer, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_cedula character varying, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_agendar_sesion(integer, integer, date, time without time zone, time without time zone); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_agendar_sesion(IN p_id_asignacion integer, IN p_id_modalidad integer, IN p_fecha date, IN p_hora_inicio time without time zone, IN p_hora_fin time without time zone, OUT p_id_nueva_sesion integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_terapeuta INT;
    v_conflictos INT;
BEGIN
    -- 1. Identificar al terapeuta a partir de la asignación
    SELECT id_terapeuta INTO v_id_terapeuta
    FROM asignacion_terapeuta_paciente
    WHERE id_asignacion = p_id_asignacion;

    -- 2. Contar si el terapeuta ya tiene sesiones que choquen en horario
    SELECT COUNT(*) INTO v_conflictos
    FROM sesion s
    JOIN asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
    WHERE a.id_terapeuta = v_id_terapeuta
      AND s.fecha = p_fecha
      AND s.id_estado_sesion = 1 
      AND (p_hora_inicio < s.hora_fin AND p_hora_fin > s.hora_inicio);

    -- 3. Decidir si insertamos o bloqueamos la acción
    IF v_conflictos > 0 THEN
        p_id_nueva_sesion := NULL;
        p_mensaje := 'Bloqueo del sistema: El terapeuta ya tiene una sesión en ese horario.';
    ELSE
        -- No hay conflicto, procedemos con el registro normal
        INSERT INTO sesion (id_asignacion, id_estado_sesion, id_modalidad, fecha, hora_inicio, hora_fin)
        VALUES (p_id_asignacion, 1, p_id_modalidad, p_fecha, p_hora_inicio, p_hora_fin)
        RETURNING id_sesion INTO p_id_nueva_sesion;

        p_mensaje := 'Sesión agendada exitosamente.';
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        p_id_nueva_sesion := NULL;
        p_mensaje := 'Error al agendar sesión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_agendar_sesion(IN p_id_asignacion integer, IN p_id_modalidad integer, IN p_fecha date, IN p_hora_inicio time without time zone, IN p_hora_fin time without time zone, OUT p_id_nueva_sesion integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_asignar_terapeuta_paciente(integer, integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_asignar_terapeuta_paciente(IN p_id_terapeuta integer, IN p_id_paciente integer, IN p_asignado_por integer, OUT p_id_asignacion integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO asignacion_terapeuta_paciente (id_terapeuta, id_paciente, id_estado_asignacion, fecha_inicio, asignado_por)
    VALUES (p_id_terapeuta, p_id_paciente, 1, CURRENT_DATE, p_asignado_por)
    RETURNING id_asignacion INTO p_id_asignacion;
    
    p_mensaje := 'Asignación creada correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_asignacion := NULL;
        p_mensaje := 'Error en asignación: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_asignar_terapeuta_paciente(IN p_id_terapeuta integer, IN p_id_paciente integer, IN p_asignado_por integer, OUT p_id_asignacion integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_cancelar_sesion(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_cancelar_sesion(IN p_id_sesion integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Cambiamos el estado de la sesión a Cancelada (Asumiendo que es el id_estado_sesion = 3)
    UPDATE sesion
    SET id_estado_sesion = 3
    WHERE id_sesion = p_id_sesion;

    p_mensaje := 'Sesión cancelada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al cancelar la sesión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_cancelar_sesion(IN p_id_sesion integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_completar_sesion(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_completar_sesion(IN p_id_sesion integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE sesion SET id_estado_sesion = 2 WHERE id_sesion = p_id_sesion;
    p_mensaje := 'Sesión marcada como completada.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al completar sesión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_completar_sesion(IN p_id_sesion integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_agenda_global(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_agenda_global(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR 
        SELECT id_sesion, fecha, hora_inicio, hora_fin, modalidad, estado_sesion, terapeuta, paciente 
        FROM vw_agenda_global 
        ORDER BY fecha DESC, hora_inicio DESC;
        
    p_mensaje := 'Agenda recuperada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar agenda: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_agenda_global(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_agenda_paciente(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_agenda_paciente(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
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
    
    -- Eliminamos el bloque EXCEPTION temporalmente para ver el error real
END;
$$;


ALTER PROCEDURE public.sp_consultar_agenda_paciente(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_agenda_terapeuta(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_agenda_terapeuta(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR 
        -- Reutilizamos tu vista perfecta, pero la filtramos por tu ID
        SELECT v.id_sesion, v.fecha, v.hora_inicio, v.hora_fin, v.modalidad, v.estado_sesion, v.terapeuta, v.paciente 
        FROM vw_agenda_global v
        JOIN sesion s ON v.id_sesion = s.id_sesion
        JOIN asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        WHERE a.id_terapeuta = p_id_terapeuta
        ORDER BY v.fecha DESC, v.hora_inicio DESC;
        
    p_mensaje := 'Agenda del terapeuta recuperada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar agenda: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_agenda_terapeuta(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_asignaciones_vigentes(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_asignaciones_vigentes(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_asignacion, terapeuta_encargado, paciente_asignado, fecha_inicio
        FROM vw_asignaciones_vigentes;
        
    p_mensaje := 'Asignaciones recuperadas exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar asignaciones: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_asignaciones_vigentes(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_especialidades(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_especialidades(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_especialidad, nombre_especialidad
        FROM especialidad
        ORDER BY nombre_especialidad ASC;
        
    p_mensaje := 'Catálogo de especialidades recuperado.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar catálogo: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_especialidades(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_historial_objetivos(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_historial_objetivos(IN p_id_objetivo integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT porcentaje_avance_registrado, fecha_registro, comentario
        FROM historial_objetivo
        WHERE id_objetivo = p_id_objetivo
        ORDER BY fecha_registro DESC;
        
    p_mensaje := 'Historial recuperado correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar historial: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_historial_objetivos(IN p_id_objetivo integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_metricas_dashboard(); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_metricas_dashboard(OUT p_total_pacientes integer, OUT p_total_terapeutas integer, OUT p_total_asignaciones integer, OUT p_citas_hoy integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Contamos el total histórico de las tablas principales
    SELECT COUNT(*) INTO p_total_pacientes FROM paciente;
    SELECT COUNT(*) INTO p_total_terapeutas FROM terapeuta;
    SELECT COUNT(*) INTO p_total_asignaciones FROM asignacion_terapeuta_paciente;
    
    -- Contamos solo las sesiones donde la fecha coincida con el día actual del servidor
    SELECT COUNT(*) INTO p_citas_hoy FROM sesion WHERE fecha = CURRENT_DATE;
END;
$$;


ALTER PROCEDURE public.sp_consultar_metricas_dashboard(OUT p_total_pacientes integer, OUT p_total_terapeutas integer, OUT p_total_asignaciones integer, OUT p_citas_hoy integer) OWNER TO usuario;

--
-- Name: sp_consultar_mis_pacientes(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_mis_pacientes(IN p_id_terapeuta integer, INOUT p_cursor refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT p.id_paciente, 
               p.nombre, 
               p.apellido_paterno, 
               p.apellido_materno, 
               p.fecha_nacimiento, 
               p.sexo, 
               p.telefono
        FROM paciente p
        JOIN asignacion_terapeuta_paciente a ON p.id_paciente = a.id_paciente
        WHERE a.id_terapeuta = p_id_terapeuta
        ORDER BY p.nombre ASC;
END;
$$;


ALTER PROCEDURE public.sp_consultar_mis_pacientes(IN p_id_terapeuta integer, INOUT p_cursor refcursor) OWNER TO usuario;

--
-- Name: sp_consultar_paciente_usuario(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_paciente_usuario(IN p_id_usuario integer, OUT p_id_paciente integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_paciente INTO p_id_paciente
    FROM paciente
    WHERE id_usuario = p_id_usuario;
END;
$$;


ALTER PROCEDURE public.sp_consultar_paciente_usuario(IN p_id_usuario integer, OUT p_id_paciente integer) OWNER TO usuario;

--
-- Name: sp_consultar_pacientes(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_pacientes(IN p_id_estado integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_paciente, nombre, apellido_paterno, apellido_materno, telefono
        FROM paciente
        WHERE id_estado_paciente = p_id_estado;
        
    p_mensaje := 'Consulta de pacientes ejecutada correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en la consulta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_pacientes(IN p_id_estado integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_sesiones_paciente(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_sesiones_paciente(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT s.id_sesion, s.fecha, s.hora_inicio, s.hora_fin, m.nombre AS modalidad,
               t.nombre || ' ' || t.apellido_paterno AS terapeuta_nombre
        FROM sesion s
        JOIN asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        JOIN terapeuta t ON a.id_terapeuta = t.id_terapeuta
        JOIN modalidad_sesion m ON s.id_modalidad = m.id_modalidad
        WHERE a.id_paciente = p_id_paciente AND s.id_estado_sesion = 1
        ORDER BY s.fecha ASC, s.hora_inicio ASC;
        
    p_mensaje := 'Sesiones del paciente recuperadas correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar sesiones del paciente: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_sesiones_paciente(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_terapeuta_usuario(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_terapeuta_usuario(IN p_id_usuario integer, OUT p_id_terapeuta integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_terapeuta INTO p_id_terapeuta
    FROM terapeuta
    WHERE id_usuario = p_id_usuario;
END;
$$;


ALTER PROCEDURE public.sp_consultar_terapeuta_usuario(IN p_id_usuario integer, OUT p_id_terapeuta integer) OWNER TO usuario;

--
-- Name: sp_consultar_terapeutas(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_terapeutas(IN p_id_estado integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_terapeuta, nombre, apellido_paterno, apellido_materno, cedula_profesional
        FROM terapeuta
        WHERE id_estado_terapeuta = p_id_estado
        ORDER BY apellido_paterno ASC;
        
    p_mensaje := 'Consulta de terapeutas ejecutada correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en la consulta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_terapeutas(IN p_id_estado integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_usuario_login(character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_usuario_login(IN p_correo character varying, OUT p_id_usuario integer, OUT p_id_rol integer, OUT p_password character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_usuario, id_rol, password_hash
    INTO p_id_usuario, p_id_rol, p_password
    FROM usuario
    WHERE correo = p_correo;

    IF p_id_usuario IS NOT NULL THEN
        p_mensaje := 'Usuario encontrado.';
    ELSE
        p_mensaje := 'El correo no existe en el sistema.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_id_usuario := NULL;
        p_mensaje := 'Error de base de datos: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_usuario_login(IN p_correo character varying, OUT p_id_usuario integer, OUT p_id_rol integer, OUT p_password character varying, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_dar_baja_paciente(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_dar_baja_paciente(IN p_id_paciente integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    SELECT id_usuario INTO v_id_usuario FROM paciente WHERE id_paciente = p_id_paciente;

    UPDATE paciente SET id_estado_paciente = 2 WHERE id_paciente = p_id_paciente;
    UPDATE usuario SET id_estado_usuario = 2 WHERE id_usuario = v_id_usuario;
    
    p_mensaje := 'Paciente dado de baja lógicamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en baja lógica: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_dar_baja_paciente(IN p_id_paciente integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_dar_baja_terapeuta(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_dar_baja_terapeuta(IN p_id_terapeuta integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    SELECT id_usuario INTO v_id_usuario FROM terapeuta WHERE id_terapeuta = p_id_terapeuta;

    UPDATE terapeuta SET id_estado_terapeuta = 3 WHERE id_terapeuta = p_id_terapeuta;
    
    UPDATE usuario SET id_estado_usuario = 2 WHERE id_usuario = v_id_usuario;
    
    p_mensaje := 'Terapeuta dado de baja lógicamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en baja lógica: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_dar_baja_terapeuta(IN p_id_terapeuta integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_dashboard_metricas(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_dashboard_metricas(IN p_id_estado integer, OUT p_total_pacientes integer, OUT p_total_terapeutas integer, OUT p_sesiones_hoy integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT COUNT(*) INTO p_total_pacientes FROM paciente WHERE id_estado_paciente = p_id_estado;
    SELECT COUNT(*) INTO p_total_terapeutas FROM terapeuta WHERE id_estado_terapeuta = p_id_estado;
    SELECT COUNT(*) INTO p_sesiones_hoy FROM sesion WHERE fecha = CURRENT_DATE AND id_estado_sesion = p_id_estado;
    
    p_mensaje := 'Métricas calculadas correctamente para el Dashboard.';
EXCEPTION
    WHEN OTHERS THEN
        p_total_pacientes := 0; p_total_terapeutas := 0; p_sesiones_hoy := 0;
        p_mensaje := 'Error al calcular métricas: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_dashboard_metricas(IN p_id_estado integer, OUT p_total_pacientes integer, OUT p_total_terapeutas integer, OUT p_sesiones_hoy integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_pacientes_sin_asignar(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_pacientes_sin_asignar(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_paciente, nombre || ' ' || apellido_paterno || ' ' || COALESCE(apellido_materno, '') AS nombre_completo
        FROM paciente
        WHERE id_estado_paciente = 1 
        AND id_paciente NOT IN (
            SELECT id_paciente FROM asignacion_terapeuta_paciente WHERE id_estado_asignacion = 1
        )
        ORDER BY nombre ASC;
        
    p_mensaje := 'Lista de pacientes sin asignar recuperada.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar pacientes sin asignar: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_pacientes_sin_asignar(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_obtener_modalidades(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_modalidades(INOUT p_cursor refcursor)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR SELECT id_modalidad, nombre FROM modalidad_sesion;
END;
$$;


ALTER PROCEDURE public.sp_obtener_modalidades(INOUT p_cursor refcursor) OWNER TO usuario;

--
-- Name: sp_obtener_paciente_por_id(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_paciente_por_id(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_paciente, nombre, apellido_paterno, apellido_materno, fecha_nacimiento, sexo, telefono
        FROM paciente
        WHERE id_paciente = p_id_paciente;
        
    p_mensaje := 'Paciente recuperado exitosamente para edición.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar el paciente: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_paciente_por_id(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_obtener_terapeuta_por_id(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_terapeuta_por_id(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_terapeuta, nombre, apellido_paterno, apellido_materno, cedula_profesional
        FROM terapeuta
        WHERE id_terapeuta = p_id_terapeuta;
        
    p_mensaje := 'Terapeuta recuperado exitosamente para edición.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar el terapeuta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_terapeuta_por_id(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_obtener_usuario_login(character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_usuario_login(IN p_correo character varying, OUT p_id_usuario integer, OUT p_id_rol integer, OUT p_hash character varying, OUT p_id_estado integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_usuario, id_rol, password_hash, id_estado_usuario
    INTO p_id_usuario, p_id_rol, p_hash, p_id_estado
    FROM usuario
    WHERE correo = p_correo;

    IF FOUND THEN
        p_mensaje := 'Usuario encontrado.';
    ELSE
        p_mensaje := 'El correo no existe en el sistema.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en la base de datos: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_usuario_login(IN p_correo character varying, OUT p_id_usuario integer, OUT p_id_rol integer, OUT p_hash character varying, OUT p_id_estado integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_registrar_avance_objetivo(integer, numeric, text, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_avance_objetivo(IN p_id_objetivo integer, IN p_porcentaje numeric, IN p_comentario text, IN p_registrado_por integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO historial_objetivo (id_objetivo, porcentaje_avance_registrado, comentario, registrado_por)
    VALUES (p_id_objetivo, p_porcentaje, p_comentario, p_registrado_por);
    
    IF p_porcentaje = 100.00 THEN
        UPDATE objetivo SET id_estado_objetivo = 2 WHERE id_objetivo = p_id_objetivo;
    END IF;
    
    p_mensaje := 'Avance registrado con éxito.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al registrar avance: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_avance_objetivo(IN p_id_objetivo integer, IN p_porcentaje numeric, IN p_comentario text, IN p_registrado_por integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_registrar_paciente(character varying, character varying, character varying, character varying, character varying, date, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_paciente(IN p_correo character varying, IN p_password_hash character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_fecha_nac date, IN p_sexo character varying, IN p_telefono character varying, OUT p_id_nuevo integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    -- Verificamos si el correo ya existe en la tabla usuario
    SELECT id_usuario INTO v_id_usuario FROM usuario WHERE correo = p_correo;

    IF v_id_usuario IS NOT NULL THEN
        -- Si ya existe, reactivamos al usuario y su perfil de paciente actualizando sus datos
        UPDATE usuario SET id_estado_usuario = 1, password_hash = p_password_hash 
        WHERE id_usuario = v_id_usuario;

        UPDATE paciente 
        SET id_estado_paciente = 1,
            nombre = p_nombre,
            apellido_paterno = p_ap_pat,
            apellido_materno = p_ap_mat,
            fecha_nacimiento = p_fecha_nac,
            sexo = p_sexo,
            telefono = p_telefono
        WHERE id_usuario = v_id_usuario
        RETURNING id_paciente INTO p_id_nuevo;

        p_mensaje := 'Paciente existente reactivado y actualizado exitosamente.';
    ELSE
        -- Si es un correo nuevo, hacemos el registro normal
        INSERT INTO usuario (id_rol, id_estado_usuario, correo, password_hash)
        VALUES (3, 1, p_correo, p_password_hash)
        RETURNING id_usuario INTO v_id_usuario;

        INSERT INTO paciente (id_usuario, id_estado_paciente, nombre, apellido_paterno, apellido_materno, fecha_nacimiento, sexo, telefono)
        VALUES (v_id_usuario, 1, p_nombre, p_ap_pat, p_ap_mat, p_fecha_nac, p_sexo, p_telefono)
        RETURNING id_paciente INTO p_id_nuevo;

        p_mensaje := 'Paciente registrado exitosamente.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_id_nuevo := NULL;
        p_mensaje := 'Error al registrar paciente: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_paciente(IN p_correo character varying, IN p_password_hash character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_fecha_nac date, IN p_sexo character varying, IN p_telefono character varying, OUT p_id_nuevo integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_registrar_terapeuta(character varying, character varying, character varying, character varying, character varying, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_terapeuta(IN p_correo character varying, IN p_password_hash character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_cedula character varying, OUT p_id_nuevo integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_usuario INT;
BEGIN
    SELECT id_usuario INTO v_id_usuario FROM usuario WHERE correo = p_correo;

    IF v_id_usuario IS NOT NULL THEN
        UPDATE usuario SET id_estado_usuario = 1, password_hash = p_password_hash 
        WHERE id_usuario = v_id_usuario;

        UPDATE terapeuta 
        SET id_estado_terapeuta = 1,
            nombre = p_nombre,
            apellido_paterno = p_ap_pat,
            apellido_materno = p_ap_mat,
            cedula_profesional = p_cedula
        WHERE id_usuario = v_id_usuario
        RETURNING id_terapeuta INTO p_id_nuevo;

        p_mensaje := 'Terapeuta reactivado y actualizado exitosamente.';
    ELSE
        INSERT INTO usuario (id_rol, id_estado_usuario, correo, password_hash)
        VALUES (2, 1, p_correo, p_password_hash)
        RETURNING id_usuario INTO v_id_usuario;

        INSERT INTO terapeuta (id_usuario, id_estado_terapeuta, nombre, apellido_paterno, apellido_materno, cedula_profesional)
        VALUES (v_id_usuario, 1, p_nombre, p_ap_pat, p_ap_mat, p_cedula)
        RETURNING id_terapeuta INTO p_id_nuevo;

        p_mensaje := 'Terapeuta registrado exitosamente.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_id_nuevo := NULL;
        p_mensaje := 'Error al registrar terapeuta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_terapeuta(IN p_correo character varying, IN p_password_hash character varying, IN p_nombre character varying, IN p_ap_pat character varying, IN p_ap_mat character varying, IN p_cedula character varying, OUT p_id_nuevo integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_reprogramar_sesion(integer, date, time without time zone, time without time zone); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_reprogramar_sesion(IN p_id_sesion integer, IN p_nueva_fecha date, IN p_nueva_hora_inicio time without time zone, IN p_nueva_hora_fin time without time zone, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE sesion
    SET fecha = p_nueva_fecha, 
        hora_inicio = p_nueva_hora_inicio, 
        hora_fin = p_nueva_hora_fin
    WHERE id_sesion = p_id_sesion;
    
    p_mensaje := 'La sesión fue reprogramada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al reprogramar la sesión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_reprogramar_sesion(IN p_id_sesion integer, IN p_nueva_fecha date, IN p_nueva_hora_inicio time without time zone, IN p_nueva_hora_fin time without time zone, OUT p_mensaje character varying) OWNER TO usuario;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: alerta; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.alerta (
    id_alerta integer NOT NULL,
    id_paciente integer,
    id_terapeuta integer,
    id_tipo_alerta integer,
    descripcion text,
    fecha_generacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    atendida boolean DEFAULT false
);


ALTER TABLE public.alerta OWNER TO usuario;

--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.alerta_id_alerta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.alerta_id_alerta_seq OWNER TO usuario;

--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.alerta_id_alerta_seq OWNED BY public.alerta.id_alerta;


--
-- Name: aplicacion_instrumento; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.aplicacion_instrumento (
    id_aplicacion integer NOT NULL,
    id_instrumento integer,
    id_paciente integer,
    id_terapeuta integer,
    fecha_asignacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    fecha_respuesta timestamp without time zone,
    estado character varying(50),
    id_documento_mongo character varying(24)
);


ALTER TABLE public.aplicacion_instrumento OWNER TO usuario;

--
-- Name: aplicacion_instrumento_id_aplicacion_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.aplicacion_instrumento_id_aplicacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.aplicacion_instrumento_id_aplicacion_seq OWNER TO usuario;

--
-- Name: aplicacion_instrumento_id_aplicacion_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.aplicacion_instrumento_id_aplicacion_seq OWNED BY public.aplicacion_instrumento.id_aplicacion;


--
-- Name: asignacion_terapeuta_paciente; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.asignacion_terapeuta_paciente (
    id_asignacion integer NOT NULL,
    id_terapeuta integer,
    id_paciente integer,
    id_estado_asignacion integer,
    fecha_inicio date NOT NULL,
    fecha_fin date,
    asignado_por integer
);


ALTER TABLE public.asignacion_terapeuta_paciente OWNER TO usuario;

--
-- Name: asignacion_terapeuta_paciente_id_asignacion_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.asignacion_terapeuta_paciente_id_asignacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.asignacion_terapeuta_paciente_id_asignacion_seq OWNER TO usuario;

--
-- Name: asignacion_terapeuta_paciente_id_asignacion_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.asignacion_terapeuta_paciente_id_asignacion_seq OWNED BY public.asignacion_terapeuta_paciente.id_asignacion;


--
-- Name: auditoria; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.auditoria (
    id_auditoria integer NOT NULL,
    id_usuario integer,
    accion character varying(50) NOT NULL,
    modulo character varying(50),
    nombre_tabla_afectada character varying(50),
    id_registro integer,
    fecha_hora timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    direccion_ip character varying(45),
    resultado character varying(50)
);


ALTER TABLE public.auditoria OWNER TO usuario;

--
-- Name: auditoria_id_auditoria_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.auditoria_id_auditoria_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.auditoria_id_auditoria_seq OWNER TO usuario;

--
-- Name: auditoria_id_auditoria_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.auditoria_id_auditoria_seq OWNED BY public.auditoria.id_auditoria;


--
-- Name: dimension_instrumento; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.dimension_instrumento (
    id_dimension integer NOT NULL,
    id_instrumento integer,
    nombre_dimension character varying(100) NOT NULL
);


ALTER TABLE public.dimension_instrumento OWNER TO usuario;

--
-- Name: dimension_instrumento_id_dimension_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.dimension_instrumento_id_dimension_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.dimension_instrumento_id_dimension_seq OWNER TO usuario;

--
-- Name: dimension_instrumento_id_dimension_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.dimension_instrumento_id_dimension_seq OWNED BY public.dimension_instrumento.id_dimension;


--
-- Name: especialidad; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.especialidad (
    id_especialidad integer NOT NULL,
    nombre_especialidad character varying(100) NOT NULL
);


ALTER TABLE public.especialidad OWNER TO usuario;

--
-- Name: especialidad_id_especialidad_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.especialidad_id_especialidad_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.especialidad_id_especialidad_seq OWNER TO usuario;

--
-- Name: especialidad_id_especialidad_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.especialidad_id_especialidad_seq OWNED BY public.especialidad.id_especialidad;


--
-- Name: estado_asignacion; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_asignacion (
    id_estado_asignacion integer NOT NULL,
    nombre_estado character varying(50) NOT NULL
);


ALTER TABLE public.estado_asignacion OWNER TO usuario;

--
-- Name: estado_asignacion_id_estado_asignacion_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_asignacion_id_estado_asignacion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_asignacion_id_estado_asignacion_seq OWNER TO usuario;

--
-- Name: estado_asignacion_id_estado_asignacion_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_asignacion_id_estado_asignacion_seq OWNED BY public.estado_asignacion.id_estado_asignacion;


--
-- Name: estado_objetivo; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_objetivo (
    id_estado_objetivo integer NOT NULL,
    nombre character varying(50) NOT NULL
);


ALTER TABLE public.estado_objetivo OWNER TO usuario;

--
-- Name: estado_objetivo_id_estado_objetivo_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_objetivo_id_estado_objetivo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_objetivo_id_estado_objetivo_seq OWNER TO usuario;

--
-- Name: estado_objetivo_id_estado_objetivo_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_objetivo_id_estado_objetivo_seq OWNED BY public.estado_objetivo.id_estado_objetivo;


--
-- Name: estado_paciente; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_paciente (
    id_estado_paciente integer NOT NULL,
    nombre_estado character varying(50) NOT NULL
);


ALTER TABLE public.estado_paciente OWNER TO usuario;

--
-- Name: estado_paciente_id_estado_paciente_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_paciente_id_estado_paciente_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_paciente_id_estado_paciente_seq OWNER TO usuario;

--
-- Name: estado_paciente_id_estado_paciente_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_paciente_id_estado_paciente_seq OWNED BY public.estado_paciente.id_estado_paciente;


--
-- Name: estado_plan; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_plan (
    id_estado_plan integer NOT NULL,
    nombre character varying(50) NOT NULL
);


ALTER TABLE public.estado_plan OWNER TO usuario;

--
-- Name: estado_plan_id_estado_plan_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_plan_id_estado_plan_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_plan_id_estado_plan_seq OWNER TO usuario;

--
-- Name: estado_plan_id_estado_plan_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_plan_id_estado_plan_seq OWNED BY public.estado_plan.id_estado_plan;


--
-- Name: estado_sesion; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_sesion (
    id_estado_sesion integer NOT NULL,
    nombre character varying(50) NOT NULL
);


ALTER TABLE public.estado_sesion OWNER TO usuario;

--
-- Name: estado_sesion_id_estado_sesion_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_sesion_id_estado_sesion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_sesion_id_estado_sesion_seq OWNER TO usuario;

--
-- Name: estado_sesion_id_estado_sesion_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_sesion_id_estado_sesion_seq OWNED BY public.estado_sesion.id_estado_sesion;


--
-- Name: estado_terapeuta; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_terapeuta (
    id_estado_terapeuta integer NOT NULL,
    nombre_estado character varying(50) NOT NULL
);


ALTER TABLE public.estado_terapeuta OWNER TO usuario;

--
-- Name: estado_terapeuta_id_estado_terapeuta_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_terapeuta_id_estado_terapeuta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_terapeuta_id_estado_terapeuta_seq OWNER TO usuario;

--
-- Name: estado_terapeuta_id_estado_terapeuta_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_terapeuta_id_estado_terapeuta_seq OWNED BY public.estado_terapeuta.id_estado_terapeuta;


--
-- Name: estado_usuario; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.estado_usuario (
    id_estado_usuario integer NOT NULL,
    nombre_estado character varying(50) NOT NULL
);


ALTER TABLE public.estado_usuario OWNER TO usuario;

--
-- Name: estado_usuario_id_estado_usuario_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.estado_usuario_id_estado_usuario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.estado_usuario_id_estado_usuario_seq OWNER TO usuario;

--
-- Name: estado_usuario_id_estado_usuario_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.estado_usuario_id_estado_usuario_seq OWNED BY public.estado_usuario.id_estado_usuario;


--
-- Name: historial_objetivo; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.historial_objetivo (
    id_historial integer NOT NULL,
    id_objetivo integer,
    porcentaje_avance_registrado numeric(5,2),
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    comentario text,
    registrado_por integer,
    CONSTRAINT historial_objetivo_porcentaje_avance_registrado_check CHECK (((porcentaje_avance_registrado >= (0)::numeric) AND (porcentaje_avance_registrado <= (100)::numeric)))
);


ALTER TABLE public.historial_objetivo OWNER TO usuario;

--
-- Name: historial_objetivo_id_historial_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.historial_objetivo_id_historial_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.historial_objetivo_id_historial_seq OWNER TO usuario;

--
-- Name: historial_objetivo_id_historial_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.historial_objetivo_id_historial_seq OWNED BY public.historial_objetivo.id_historial;


--
-- Name: instrumento; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.instrumento (
    id_instrumento integer NOT NULL,
    nombre character varying(150) NOT NULL,
    descripcion text,
    estado character varying(50),
    version character varying(20),
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.instrumento OWNER TO usuario;

--
-- Name: instrumento_id_instrumento_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.instrumento_id_instrumento_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.instrumento_id_instrumento_seq OWNER TO usuario;

--
-- Name: instrumento_id_instrumento_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.instrumento_id_instrumento_seq OWNED BY public.instrumento.id_instrumento;


--
-- Name: modalidad_sesion; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.modalidad_sesion (
    id_modalidad integer NOT NULL,
    nombre character varying(50) NOT NULL
);


ALTER TABLE public.modalidad_sesion OWNER TO usuario;

--
-- Name: modalidad_sesion_id_modalidad_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.modalidad_sesion_id_modalidad_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.modalidad_sesion_id_modalidad_seq OWNER TO usuario;

--
-- Name: modalidad_sesion_id_modalidad_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.modalidad_sesion_id_modalidad_seq OWNED BY public.modalidad_sesion.id_modalidad;


--
-- Name: objetivo; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.objetivo (
    id_objetivo integer NOT NULL,
    id_plan integer,
    id_estado_objetivo integer,
    nombre character varying(200) NOT NULL,
    descripcion text,
    fecha_inicio date,
    fecha_meta date
);


ALTER TABLE public.objetivo OWNER TO usuario;

--
-- Name: objetivo_id_objetivo_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.objetivo_id_objetivo_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.objetivo_id_objetivo_seq OWNER TO usuario;

--
-- Name: objetivo_id_objetivo_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.objetivo_id_objetivo_seq OWNED BY public.objetivo.id_objetivo;


--
-- Name: paciente; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.paciente (
    id_paciente integer NOT NULL,
    id_usuario integer,
    id_estado_paciente integer,
    nombre character varying(100) NOT NULL,
    apellido_paterno character varying(100) NOT NULL,
    apellido_materno character varying(100),
    fecha_nacimiento date NOT NULL,
    sexo character varying(20),
    telefono character varying(20),
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.paciente OWNER TO usuario;

--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.paciente_id_paciente_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.paciente_id_paciente_seq OWNER TO usuario;

--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.paciente_id_paciente_seq OWNED BY public.paciente.id_paciente;


--
-- Name: permiso; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.permiso (
    id_permiso integer NOT NULL,
    nombre_permiso character varying(100) NOT NULL,
    modulo character varying(50) NOT NULL
);


ALTER TABLE public.permiso OWNER TO usuario;

--
-- Name: permiso_id_permiso_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.permiso_id_permiso_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.permiso_id_permiso_seq OWNER TO usuario;

--
-- Name: permiso_id_permiso_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.permiso_id_permiso_seq OWNED BY public.permiso.id_permiso;


--
-- Name: plan_terapeutico; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.plan_terapeutico (
    id_plan integer NOT NULL,
    id_asignacion integer,
    id_estado_plan integer,
    fecha_inicio date NOT NULL,
    fecha_fin date,
    descripcion_general text,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.plan_terapeutico OWNER TO usuario;

--
-- Name: plan_terapeutico_id_plan_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.plan_terapeutico_id_plan_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.plan_terapeutico_id_plan_seq OWNER TO usuario;

--
-- Name: plan_terapeutico_id_plan_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.plan_terapeutico_id_plan_seq OWNED BY public.plan_terapeutico.id_plan;


--
-- Name: referencia_bitacora; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.referencia_bitacora (
    id_referencia integer NOT NULL,
    id_paciente integer,
    fecha_registro timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    id_documento_mongo character varying(24)
);


ALTER TABLE public.referencia_bitacora OWNER TO usuario;

--
-- Name: referencia_bitacora_id_referencia_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.referencia_bitacora_id_referencia_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.referencia_bitacora_id_referencia_seq OWNER TO usuario;

--
-- Name: referencia_bitacora_id_referencia_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.referencia_bitacora_id_referencia_seq OWNED BY public.referencia_bitacora.id_referencia;


--
-- Name: referencia_resumen; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.referencia_resumen (
    id_referencia integer NOT NULL,
    id_sesion integer,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    id_documento_mongo character varying(24)
);


ALTER TABLE public.referencia_resumen OWNER TO usuario;

--
-- Name: referencia_resumen_id_referencia_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.referencia_resumen_id_referencia_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.referencia_resumen_id_referencia_seq OWNER TO usuario;

--
-- Name: referencia_resumen_id_referencia_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.referencia_resumen_id_referencia_seq OWNED BY public.referencia_resumen.id_referencia;


--
-- Name: resultado_instrumento; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.resultado_instrumento (
    id_resultado integer NOT NULL,
    id_aplicacion integer,
    id_dimension integer,
    puntuacion_bruta numeric(10,2),
    fecha_calculo timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.resultado_instrumento OWNER TO usuario;

--
-- Name: resultado_instrumento_id_resultado_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.resultado_instrumento_id_resultado_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.resultado_instrumento_id_resultado_seq OWNER TO usuario;

--
-- Name: resultado_instrumento_id_resultado_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.resultado_instrumento_id_resultado_seq OWNED BY public.resultado_instrumento.id_resultado;


--
-- Name: rol; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.rol (
    id_rol integer NOT NULL,
    nombre character varying(50) NOT NULL,
    descripcion text
);


ALTER TABLE public.rol OWNER TO usuario;

--
-- Name: rol_id_rol_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.rol_id_rol_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.rol_id_rol_seq OWNER TO usuario;

--
-- Name: rol_id_rol_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.rol_id_rol_seq OWNED BY public.rol.id_rol;


--
-- Name: rol_permiso; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.rol_permiso (
    id_rol integer NOT NULL,
    id_permiso integer NOT NULL
);


ALTER TABLE public.rol_permiso OWNER TO usuario;

--
-- Name: sesion; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.sesion (
    id_sesion integer NOT NULL,
    id_asignacion integer,
    id_estado_sesion integer,
    id_modalidad integer,
    fecha date NOT NULL,
    hora_inicio time without time zone NOT NULL,
    hora_fin time without time zone NOT NULL,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.sesion OWNER TO usuario;

--
-- Name: sesion_id_sesion_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.sesion_id_sesion_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.sesion_id_sesion_seq OWNER TO usuario;

--
-- Name: sesion_id_sesion_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.sesion_id_sesion_seq OWNED BY public.sesion.id_sesion;


--
-- Name: terapeuta; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.terapeuta (
    id_terapeuta integer NOT NULL,
    id_usuario integer,
    id_estado_terapeuta integer,
    nombre character varying(100) NOT NULL,
    apellido_paterno character varying(100) NOT NULL,
    apellido_materno character varying(100),
    cedula_profesional character varying(50) NOT NULL
);


ALTER TABLE public.terapeuta OWNER TO usuario;

--
-- Name: terapeuta_especialidad; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.terapeuta_especialidad (
    id_terapeuta integer NOT NULL,
    id_especialidad integer NOT NULL
);


ALTER TABLE public.terapeuta_especialidad OWNER TO usuario;

--
-- Name: terapeuta_id_terapeuta_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.terapeuta_id_terapeuta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.terapeuta_id_terapeuta_seq OWNER TO usuario;

--
-- Name: terapeuta_id_terapeuta_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.terapeuta_id_terapeuta_seq OWNED BY public.terapeuta.id_terapeuta;


--
-- Name: tipo_alerta; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.tipo_alerta (
    id_tipo_alerta integer NOT NULL,
    nombre character varying(100) NOT NULL,
    descripcion text
);


ALTER TABLE public.tipo_alerta OWNER TO usuario;

--
-- Name: tipo_alerta_id_tipo_alerta_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.tipo_alerta_id_tipo_alerta_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.tipo_alerta_id_tipo_alerta_seq OWNER TO usuario;

--
-- Name: tipo_alerta_id_tipo_alerta_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.tipo_alerta_id_tipo_alerta_seq OWNED BY public.tipo_alerta.id_tipo_alerta;


--
-- Name: usuario; Type: TABLE; Schema: public; Owner: usuario
--

CREATE TABLE public.usuario (
    id_usuario integer NOT NULL,
    id_rol integer,
    id_estado_usuario integer,
    correo character varying(150) NOT NULL,
    password_hash character varying(255) NOT NULL,
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    ultimo_acceso timestamp without time zone
);


ALTER TABLE public.usuario OWNER TO usuario;

--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE; Schema: public; Owner: usuario
--

CREATE SEQUENCE public.usuario_id_usuario_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.usuario_id_usuario_seq OWNER TO usuario;

--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: usuario
--

ALTER SEQUENCE public.usuario_id_usuario_seq OWNED BY public.usuario.id_usuario;


--
-- Name: vw_agenda_global; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_agenda_global AS
 SELECT s.id_sesion,
    s.fecha,
    s.hora_inicio,
    s.hora_fin,
    m.nombre AS modalidad,
    es.nombre AS estado_sesion,
    (((t.nombre)::text || ' '::text) || (t.apellido_paterno)::text) AS terapeuta,
    (((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) AS paciente
   FROM (((((public.sesion s
     JOIN public.modalidad_sesion m ON ((s.id_modalidad = m.id_modalidad)))
     JOIN public.estado_sesion es ON ((s.id_estado_sesion = es.id_estado_sesion)))
     JOIN public.asignacion_terapeuta_paciente a ON ((s.id_asignacion = a.id_asignacion)))
     JOIN public.terapeuta t ON ((a.id_terapeuta = t.id_terapeuta)))
     JOIN public.paciente p ON ((a.id_paciente = p.id_paciente)));


ALTER VIEW public.vw_agenda_global OWNER TO usuario;

--
-- Name: vw_alertas_activas; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_alertas_activas AS
 SELECT a.id_alerta,
    ta.nombre AS tipo_alerta,
    a.descripcion,
    (((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) AS paciente,
    (((t.nombre)::text || ' '::text) || (t.apellido_paterno)::text) AS terapeuta_notificado,
    a.fecha_generacion
   FROM (((public.alerta a
     JOIN public.tipo_alerta ta ON ((a.id_tipo_alerta = ta.id_tipo_alerta)))
     JOIN public.paciente p ON ((a.id_paciente = p.id_paciente)))
     JOIN public.terapeuta t ON ((a.id_terapeuta = t.id_terapeuta)))
  WHERE (a.atendida = false)
  ORDER BY a.fecha_generacion DESC;


ALTER VIEW public.vw_alertas_activas OWNER TO usuario;

--
-- Name: vw_asignaciones_vigentes; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_asignaciones_vigentes AS
 SELECT atp.id_asignacion,
    (((t.nombre)::text || ' '::text) || (t.apellido_paterno)::text) AS terapeuta_encargado,
    (((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) AS paciente_asignado,
    atp.fecha_inicio
   FROM ((public.asignacion_terapeuta_paciente atp
     JOIN public.terapeuta t ON ((atp.id_terapeuta = t.id_terapeuta)))
     JOIN public.paciente p ON ((atp.id_paciente = p.id_paciente)))
  WHERE (atp.id_estado_asignacion = 1)
  ORDER BY atp.fecha_inicio DESC;


ALTER VIEW public.vw_asignaciones_vigentes OWNER TO usuario;

--
-- Name: vw_directorio_pacientes; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_directorio_pacientes AS
 SELECT p.id_paciente,
    (((((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) || ' '::text) || (COALESCE(p.apellido_materno, ''::character varying))::text) AS nombre_completo,
    p.telefono,
    u.correo,
    e.nombre_estado AS estatus_cuenta,
    p.fecha_registro
   FROM ((public.paciente p
     JOIN public.usuario u ON ((p.id_usuario = u.id_usuario)))
     JOIN public.estado_paciente e ON ((p.id_estado_paciente = e.id_estado_paciente)));


ALTER VIEW public.vw_directorio_pacientes OWNER TO usuario;

--
-- Name: vw_directorio_terapeutas; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_directorio_terapeutas AS
 SELECT t.id_terapeuta,
    (((t.nombre)::text || ' '::text) || (t.apellido_paterno)::text) AS nombre_terapeuta,
    t.cedula_profesional,
    string_agg((e.nombre_especialidad)::text, ', '::text) AS especialidades,
    et.nombre_estado AS estatus
   FROM (((public.terapeuta t
     JOIN public.estado_terapeuta et ON ((t.id_estado_terapeuta = et.id_estado_terapeuta)))
     LEFT JOIN public.terapeuta_especialidad te ON ((t.id_terapeuta = te.id_terapeuta)))
     LEFT JOIN public.especialidad e ON ((te.id_especialidad = e.id_especialidad)))
  GROUP BY t.id_terapeuta, t.nombre, t.apellido_paterno, t.cedula_profesional, et.nombre_estado;


ALTER VIEW public.vw_directorio_terapeutas OWNER TO usuario;

--
-- Name: vw_progreso_clinico; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_progreso_clinico AS
 SELECT (((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) AS paciente,
    o.nombre AS objetivo_terapeutico,
    eo.nombre AS estado_objetivo,
    h.porcentaje_avance_registrado AS avance_actual,
    h.fecha_registro AS ultima_actualizacion,
    h.comentario
   FROM (((((public.objetivo o
     JOIN public.estado_objetivo eo ON ((o.id_estado_objetivo = eo.id_estado_objetivo)))
     JOIN public.plan_terapeutico pt ON ((o.id_plan = pt.id_plan)))
     JOIN public.asignacion_terapeuta_paciente a ON ((pt.id_asignacion = a.id_asignacion)))
     JOIN public.paciente p ON ((a.id_paciente = p.id_paciente)))
     LEFT JOIN public.historial_objetivo h ON (((h.id_objetivo = o.id_objetivo) AND (h.fecha_registro = ( SELECT max(historial_objetivo.fecha_registro) AS max
           FROM public.historial_objetivo
          WHERE (historial_objetivo.id_objetivo = o.id_objetivo))))));


ALTER VIEW public.vw_progreso_clinico OWNER TO usuario;

--
-- Name: vw_reporte_auditoria; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_reporte_auditoria AS
 SELECT au.id_auditoria,
    au.fecha_hora,
    COALESCE(u.correo, 'Sistema/Anónimo'::character varying) AS usuario_responsable,
    au.accion,
    au.modulo,
    au.nombre_tabla_afectada,
    au.direccion_ip,
    au.resultado
   FROM (public.auditoria au
     LEFT JOIN public.usuario u ON ((au.id_usuario = u.id_usuario)))
  ORDER BY au.fecha_hora DESC;


ALTER VIEW public.vw_reporte_auditoria OWNER TO usuario;

--
-- Name: vw_resultados_instrumentos; Type: VIEW; Schema: public; Owner: usuario
--

CREATE VIEW public.vw_resultados_instrumentos AS
 SELECT ai.id_aplicacion,
    i.nombre AS instrumento,
    (((p.nombre)::text || ' '::text) || (p.apellido_paterno)::text) AS paciente,
    di.nombre_dimension AS dimension_evaluada,
    ri.puntuacion_bruta,
    ai.fecha_respuesta
   FROM ((((public.aplicacion_instrumento ai
     JOIN public.instrumento i ON ((ai.id_instrumento = i.id_instrumento)))
     JOIN public.paciente p ON ((ai.id_paciente = p.id_paciente)))
     JOIN public.resultado_instrumento ri ON ((ai.id_aplicacion = ri.id_aplicacion)))
     JOIN public.dimension_instrumento di ON ((ri.id_dimension = di.id_dimension)))
  ORDER BY ai.fecha_respuesta DESC;


ALTER VIEW public.vw_resultados_instrumentos OWNER TO usuario;

--
-- Name: alerta id_alerta; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.alerta ALTER COLUMN id_alerta SET DEFAULT nextval('public.alerta_id_alerta_seq'::regclass);


--
-- Name: aplicacion_instrumento id_aplicacion; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.aplicacion_instrumento ALTER COLUMN id_aplicacion SET DEFAULT nextval('public.aplicacion_instrumento_id_aplicacion_seq'::regclass);


--
-- Name: asignacion_terapeuta_paciente id_asignacion; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente ALTER COLUMN id_asignacion SET DEFAULT nextval('public.asignacion_terapeuta_paciente_id_asignacion_seq'::regclass);


--
-- Name: auditoria id_auditoria; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.auditoria ALTER COLUMN id_auditoria SET DEFAULT nextval('public.auditoria_id_auditoria_seq'::regclass);


--
-- Name: dimension_instrumento id_dimension; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.dimension_instrumento ALTER COLUMN id_dimension SET DEFAULT nextval('public.dimension_instrumento_id_dimension_seq'::regclass);


--
-- Name: especialidad id_especialidad; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.especialidad ALTER COLUMN id_especialidad SET DEFAULT nextval('public.especialidad_id_especialidad_seq'::regclass);


--
-- Name: estado_asignacion id_estado_asignacion; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_asignacion ALTER COLUMN id_estado_asignacion SET DEFAULT nextval('public.estado_asignacion_id_estado_asignacion_seq'::regclass);


--
-- Name: estado_objetivo id_estado_objetivo; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_objetivo ALTER COLUMN id_estado_objetivo SET DEFAULT nextval('public.estado_objetivo_id_estado_objetivo_seq'::regclass);


--
-- Name: estado_paciente id_estado_paciente; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_paciente ALTER COLUMN id_estado_paciente SET DEFAULT nextval('public.estado_paciente_id_estado_paciente_seq'::regclass);


--
-- Name: estado_plan id_estado_plan; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_plan ALTER COLUMN id_estado_plan SET DEFAULT nextval('public.estado_plan_id_estado_plan_seq'::regclass);


--
-- Name: estado_sesion id_estado_sesion; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_sesion ALTER COLUMN id_estado_sesion SET DEFAULT nextval('public.estado_sesion_id_estado_sesion_seq'::regclass);


--
-- Name: estado_terapeuta id_estado_terapeuta; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_terapeuta ALTER COLUMN id_estado_terapeuta SET DEFAULT nextval('public.estado_terapeuta_id_estado_terapeuta_seq'::regclass);


--
-- Name: estado_usuario id_estado_usuario; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_usuario ALTER COLUMN id_estado_usuario SET DEFAULT nextval('public.estado_usuario_id_estado_usuario_seq'::regclass);


--
-- Name: historial_objetivo id_historial; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.historial_objetivo ALTER COLUMN id_historial SET DEFAULT nextval('public.historial_objetivo_id_historial_seq'::regclass);


--
-- Name: instrumento id_instrumento; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.instrumento ALTER COLUMN id_instrumento SET DEFAULT nextval('public.instrumento_id_instrumento_seq'::regclass);


--
-- Name: modalidad_sesion id_modalidad; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.modalidad_sesion ALTER COLUMN id_modalidad SET DEFAULT nextval('public.modalidad_sesion_id_modalidad_seq'::regclass);


--
-- Name: objetivo id_objetivo; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.objetivo ALTER COLUMN id_objetivo SET DEFAULT nextval('public.objetivo_id_objetivo_seq'::regclass);


--
-- Name: paciente id_paciente; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.paciente ALTER COLUMN id_paciente SET DEFAULT nextval('public.paciente_id_paciente_seq'::regclass);


--
-- Name: permiso id_permiso; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.permiso ALTER COLUMN id_permiso SET DEFAULT nextval('public.permiso_id_permiso_seq'::regclass);


--
-- Name: plan_terapeutico id_plan; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.plan_terapeutico ALTER COLUMN id_plan SET DEFAULT nextval('public.plan_terapeutico_id_plan_seq'::regclass);


--
-- Name: referencia_bitacora id_referencia; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_bitacora ALTER COLUMN id_referencia SET DEFAULT nextval('public.referencia_bitacora_id_referencia_seq'::regclass);


--
-- Name: referencia_resumen id_referencia; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_resumen ALTER COLUMN id_referencia SET DEFAULT nextval('public.referencia_resumen_id_referencia_seq'::regclass);


--
-- Name: resultado_instrumento id_resultado; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.resultado_instrumento ALTER COLUMN id_resultado SET DEFAULT nextval('public.resultado_instrumento_id_resultado_seq'::regclass);


--
-- Name: rol id_rol; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.rol ALTER COLUMN id_rol SET DEFAULT nextval('public.rol_id_rol_seq'::regclass);


--
-- Name: sesion id_sesion; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.sesion ALTER COLUMN id_sesion SET DEFAULT nextval('public.sesion_id_sesion_seq'::regclass);


--
-- Name: terapeuta id_terapeuta; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta ALTER COLUMN id_terapeuta SET DEFAULT nextval('public.terapeuta_id_terapeuta_seq'::regclass);


--
-- Name: tipo_alerta id_tipo_alerta; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.tipo_alerta ALTER COLUMN id_tipo_alerta SET DEFAULT nextval('public.tipo_alerta_id_tipo_alerta_seq'::regclass);


--
-- Name: usuario id_usuario; Type: DEFAULT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.usuario ALTER COLUMN id_usuario SET DEFAULT nextval('public.usuario_id_usuario_seq'::regclass);


--
-- Data for Name: alerta; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.alerta (id_alerta, id_paciente, id_terapeuta, id_tipo_alerta, descripcion, fecha_generacion, atendida) FROM stdin;
\.


--
-- Data for Name: aplicacion_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.aplicacion_instrumento (id_aplicacion, id_instrumento, id_paciente, id_terapeuta, fecha_asignacion, fecha_respuesta, estado, id_documento_mongo) FROM stdin;
\.


--
-- Data for Name: asignacion_terapeuta_paciente; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.asignacion_terapeuta_paciente (id_asignacion, id_terapeuta, id_paciente, id_estado_asignacion, fecha_inicio, fecha_fin, asignado_por) FROM stdin;
1	1	1	1	2026-08-01	\N	1
2	1	2	1	2026-08-02	\N	1
3	1	3	1	2026-08-03	\N	1
4	2	4	1	2026-08-04	\N	1
5	2	5	1	2026-08-05	\N	1
6	2	6	1	2026-08-06	\N	1
7	3	7	1	2026-08-07	\N	1
8	3	8	1	2026-08-08	\N	1
9	3	9	1	2026-08-09	\N	1
10	4	10	1	2026-08-10	\N	1
11	4	11	1	2026-08-11	\N	1
12	4	12	1	2026-08-12	\N	1
13	5	13	1	2026-08-13	\N	1
14	5	14	1	2026-08-14	\N	1
15	5	15	1	2026-08-15	\N	1
16	6	16	1	2026-08-16	\N	1
17	6	17	1	2026-08-17	\N	1
18	6	18	1	2026-08-18	\N	1
19	7	19	1	2026-08-19	\N	1
20	7	20	1	2026-08-20	\N	1
21	7	21	1	2026-08-21	\N	1
22	8	22	1	2026-08-22	\N	1
23	8	23	1	2026-08-23	\N	1
24	8	24	1	2026-08-24	\N	1
25	9	25	1	2026-08-25	\N	1
26	9	26	1	2026-08-26	\N	1
27	9	27	1	2026-08-27	\N	1
28	9	28	1	2026-08-28	\N	1
29	11	29	1	2026-10-18	\N	1
30	11	33	1	2026-10-18	\N	1
\.


--
-- Data for Name: auditoria; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.auditoria (id_auditoria, id_usuario, accion, modulo, nombre_tabla_afectada, id_registro, fecha_hora, direccion_ip, resultado) FROM stdin;
\.


--
-- Data for Name: dimension_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.dimension_instrumento (id_dimension, id_instrumento, nombre_dimension) FROM stdin;
\.


--
-- Data for Name: especialidad; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.especialidad (id_especialidad, nombre_especialidad) FROM stdin;
1	Psicología Clínica
2	Terapia Cognitivo-Conductual
3	Psiquiatría
4	Neuropsicología
5	Terapia de Pareja
6	Terapia Infantil
7	Psicoanálisis
8	Tanatología
9	Terapia Sistémica Familiar
10	Orientación Vocacional
\.


--
-- Data for Name: estado_asignacion; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_asignacion (id_estado_asignacion, nombre_estado) FROM stdin;
1	Vigente
2	Finalizada
\.


--
-- Data for Name: estado_objetivo; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_objetivo (id_estado_objetivo, nombre) FROM stdin;
1	Pendiente
2	Logrado
\.


--
-- Data for Name: estado_paciente; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_paciente (id_estado_paciente, nombre_estado) FROM stdin;
1	Activo
2	Baja Lógica
3	En Pausa
\.


--
-- Data for Name: estado_plan; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_plan (id_estado_plan, nombre) FROM stdin;
1	Activo
2	Completado
\.


--
-- Data for Name: estado_sesion; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_sesion (id_estado_sesion, nombre) FROM stdin;
1	Programada
2	Completada
3	Cancelada
\.


--
-- Data for Name: estado_terapeuta; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_terapeuta (id_estado_terapeuta, nombre_estado) FROM stdin;
1	Activo
2	Vacaciones
3	Baja
\.


--
-- Data for Name: estado_usuario; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.estado_usuario (id_estado_usuario, nombre_estado) FROM stdin;
1	Activo
2	Inactivo
\.


--
-- Data for Name: historial_objetivo; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.historial_objetivo (id_historial, id_objetivo, porcentaje_avance_registrado, fecha_registro, comentario, registrado_por) FROM stdin;
\.


--
-- Data for Name: instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.instrumento (id_instrumento, nombre, descripcion, estado, version, fecha_creacion) FROM stdin;
\.


--
-- Data for Name: modalidad_sesion; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.modalidad_sesion (id_modalidad, nombre) FROM stdin;
1	Presencial
2	Virtual
\.


--
-- Data for Name: objetivo; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.objetivo (id_objetivo, id_plan, id_estado_objetivo, nombre, descripcion, fecha_inicio, fecha_meta) FROM stdin;
\.


--
-- Data for Name: paciente; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.paciente (id_paciente, id_usuario, id_estado_paciente, nombre, apellido_paterno, apellido_materno, fecha_nacimiento, sexo, telefono, fecha_registro) FROM stdin;
2	13	1	Andrés	Sánchez	López	1995-08-22	Masculino	\N	2026-10-17 19:55:18.022182
3	14	1	Fernanda	Taha	Méndez	2003-01-10	Femenino	\N	2026-10-17 19:55:18.022182
4	15	1	Miguel	Gómez	Ortiz	1988-11-03	Masculino	\N	2026-10-17 19:55:18.022182
5	16	1	Lucía	Pérez	Hernández	1999-07-19	Femenino	\N	2026-10-17 19:55:18.022182
6	17	1	Jorge	Díaz	Castro	1992-04-25	Masculino	\N	2026-10-17 19:55:18.022182
7	18	1	Valeria	Ramírez	Vargas	2001-09-08	Femenino	\N	2026-10-17 19:55:18.022182
8	19	1	Diego	Torres	Navarro	1997-12-14	Masculino	\N	2026-10-17 19:55:18.022182
9	20	1	Camila	Flores	Silva	2004-03-30	Femenino	\N	2026-10-17 19:55:18.022182
10	21	1	Emilio	Gutiérrez	Molina	1990-06-12	Masculino	\N	2026-10-17 19:55:18.022182
11	22	1	Sara	Morales	Delgado	1985-02-18	Femenino	\N	2026-10-17 19:55:18.022182
12	23	1	Sebastián	Reyes	Rojas	1993-10-05	Masculino	\N	2026-10-17 19:55:18.022182
13	24	1	Isabella	Jiménez	Paz	2002-11-21	Femenino	\N	2026-10-17 19:55:18.022182
14	25	1	Daniel	Mendoza	Soto	1998-05-09	Masculino	\N	2026-10-17 19:55:18.022182
15	26	1	Ximena	Vega	Lara	2005-08-14	Femenino	\N	2026-10-17 19:55:18.022182
16	27	1	Mateo	Ortiz	Ríos	1996-01-27	Masculino	\N	2026-10-17 19:55:18.022182
17	28	1	Victoria	Castillo	Peña	1991-09-03	Femenino	\N	2026-10-17 19:55:18.022182
18	29	1	Nicolás	Chávez	Luna	2000-12-01	Masculino	\N	2026-10-17 19:55:18.022182
19	30	1	Martina	Ruiz	Guzmán	1987-04-11	Femenino	\N	2026-10-17 19:55:18.022182
20	31	1	Javier	Hernández	Salas	1994-07-06	Masculino	\N	2026-10-17 19:55:18.022182
21	32	1	Daniela	Medina	Cruz	2003-02-28	Femenino	\N	2026-10-17 19:55:18.022182
22	33	1	Leonardo	Cortés	Vidal	1989-10-16	Masculino	\N	2026-10-17 19:55:18.022182
23	34	1	Renata	Escobar	Mora	2001-05-04	Femenino	\N	2026-10-17 19:55:18.022182
24	35	1	Héctor	Aguilar	Pineda	1995-11-29	Masculino	\N	2026-10-17 19:55:18.022182
25	36	1	Regina	Miranda	Bello	1998-08-07	Femenino	\N	2026-10-17 19:55:18.022182
26	37	1	Hugo	Paredes	Nieto	1992-03-15	Masculino	\N	2026-10-17 19:55:18.022182
27	38	1	Samantha	Guzmán	Valle	2004-06-22	Femenino	\N	2026-10-17 19:55:18.022182
28	39	1	Mauricio	Cervantes	Blanco	1990-09-10	Masculino	\N	2026-10-17 19:55:18.022182
29	40	1	Alma	Solis	Ochoa	1999-01-05	Femenino	\N	2026-10-17 19:55:18.022182
30	41	1	Rafael	Cabrera	Acosta	1986-12-19	Masculino	\N	2026-10-17 19:55:18.022182
1	12	1	Paola	González	Ruiz	2000-05-15	Femenino	5540945977	2026-10-17 19:55:18.022182
31	42	2	Paola	Taha	Garza	2003-04-25	Femenino	5540945977	2026-10-18 02:20:41.891364
32	45	1	Paola	Taha	Garza	2003-04-25	Femenino	8127470328	2026-10-18 02:35:54.020426
33	51	1	Carlos Enrique	Aguilar	Weber	1971-04-10	Masculino	5540945977	2026-10-18 03:08:25.882202
34	48	2	Eduardo	Aguilar	Sanchez	2007-09-12	Masculino	5540945977	2026-10-18 03:37:49.230778
35	52	2	Pablo	Ramirez	Martinez	2026-10-22	Masculino	\N	2026-10-22 14:41:28.265484
\.


--
-- Data for Name: permiso; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.permiso (id_permiso, nombre_permiso, modulo) FROM stdin;
\.


--
-- Data for Name: plan_terapeutico; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.plan_terapeutico (id_plan, id_asignacion, id_estado_plan, fecha_inicio, fecha_fin, descripcion_general, fecha_creacion) FROM stdin;
\.


--
-- Data for Name: referencia_bitacora; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.referencia_bitacora (id_referencia, id_paciente, fecha_registro, id_documento_mongo) FROM stdin;
\.


--
-- Data for Name: referencia_resumen; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.referencia_resumen (id_referencia, id_sesion, fecha_creacion, id_documento_mongo) FROM stdin;
\.


--
-- Data for Name: resultado_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.resultado_instrumento (id_resultado, id_aplicacion, id_dimension, puntuacion_bruta, fecha_calculo) FROM stdin;
\.


--
-- Data for Name: rol; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.rol (id_rol, nombre, descripcion) FROM stdin;
1	Administrador	Control total del sistema
2	Terapeuta	Profesional de la salud mental
3	Paciente	Usuario que recibe el servicio
\.


--
-- Data for Name: rol_permiso; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.rol_permiso (id_rol, id_permiso) FROM stdin;
\.


--
-- Data for Name: sesion; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.sesion (id_sesion, id_asignacion, id_estado_sesion, id_modalidad, fecha, hora_inicio, hora_fin, fecha_creacion) FROM stdin;
1	1	2	1	2026-08-05	10:00:00	11:00:00	2026-10-17 19:55:18.030609
2	1	2	1	2026-08-12	10:00:00	11:00:00	2026-10-17 19:55:18.030609
3	1	2	1	2026-08-19	10:00:00	11:00:00	2026-10-17 19:55:18.030609
4	1	1	1	2026-08-26	10:00:00	11:00:00	2026-10-17 19:55:18.030609
5	2	2	2	2026-08-06	11:00:00	12:00:00	2026-10-17 19:55:18.030609
6	2	2	2	2026-08-13	11:00:00	12:00:00	2026-10-17 19:55:18.030609
7	3	2	1	2026-08-07	16:00:00	17:00:00	2026-10-17 19:55:18.030609
8	3	3	1	2026-08-14	16:00:00	17:00:00	2026-10-17 19:55:18.030609
9	4	2	1	2026-08-10	09:00:00	10:00:00	2026-10-17 19:55:18.030609
10	4	2	1	2026-08-17	09:00:00	10:00:00	2026-10-17 19:55:18.030609
11	5	2	2	2026-08-11	10:00:00	11:00:00	2026-10-17 19:55:18.030609
12	5	2	2	2026-08-18	10:00:00	11:00:00	2026-10-17 19:55:18.030609
13	6	2	1	2026-08-12	11:00:00	12:00:00	2026-10-17 19:55:18.030609
14	6	1	1	2026-08-19	11:00:00	12:00:00	2026-10-17 19:55:18.030609
15	7	2	1	2026-08-15	16:00:00	17:00:00	2026-10-17 19:55:18.030609
16	7	2	1	2026-08-22	16:00:00	17:00:00	2026-10-17 19:55:18.030609
17	8	2	2	2026-08-16	17:00:00	18:00:00	2026-10-17 19:55:18.030609
18	8	2	2	2026-08-23	17:00:00	18:00:00	2026-10-17 19:55:18.030609
19	9	2	1	2026-08-17	18:00:00	19:00:00	2026-10-17 19:55:18.030609
20	9	1	1	2026-08-24	18:00:00	19:00:00	2026-10-17 19:55:18.030609
21	10	2	1	2026-08-15	09:00:00	10:00:00	2026-10-17 19:55:18.030609
22	11	2	2	2026-08-16	10:00:00	11:00:00	2026-10-17 19:55:18.030609
23	12	2	1	2026-08-17	11:00:00	12:00:00	2026-10-17 19:55:18.030609
24	13	2	2	2026-08-18	12:00:00	13:00:00	2026-10-17 19:55:18.030609
25	14	2	1	2026-08-19	13:00:00	14:00:00	2026-10-17 19:55:18.030609
26	15	2	2	2026-08-20	14:00:00	15:00:00	2026-10-17 19:55:18.030609
27	16	2	1	2026-08-21	15:00:00	16:00:00	2026-10-17 19:55:18.030609
28	17	2	2	2026-08-22	16:00:00	17:00:00	2026-10-17 19:55:18.030609
29	18	2	1	2026-08-23	17:00:00	18:00:00	2026-10-17 19:55:18.030609
30	19	2	2	2026-08-24	18:00:00	19:00:00	2026-10-17 19:55:18.030609
31	20	2	1	2026-08-25	19:00:00	20:00:00	2026-10-17 19:55:18.030609
32	21	2	2	2026-08-26	09:00:00	10:00:00	2026-10-17 19:55:18.030609
33	22	2	1	2026-08-27	10:00:00	11:00:00	2026-10-17 19:55:18.030609
34	23	2	2	2026-08-28	11:00:00	12:00:00	2026-10-17 19:55:18.030609
35	24	2	1	2026-08-29	12:00:00	13:00:00	2026-10-17 19:55:18.030609
36	25	2	2	2026-08-30	13:00:00	14:00:00	2026-10-17 19:55:18.030609
37	26	2	1	2026-08-31	14:00:00	15:00:00	2026-10-17 19:55:18.030609
38	27	2	2	2026-09-01	15:00:00	16:00:00	2026-10-17 19:55:18.030609
39	28	2	1	2026-09-02	16:00:00	17:00:00	2026-10-17 19:55:18.030609
40	10	1	1	2026-09-03	09:00:00	10:00:00	2026-10-17 19:55:18.030609
41	11	1	2	2026-09-04	10:00:00	11:00:00	2026-10-17 19:55:18.030609
42	12	1	1	2026-09-05	11:00:00	12:00:00	2026-10-17 19:55:18.030609
43	13	1	2	2026-09-06	12:00:00	13:00:00	2026-10-17 19:55:18.030609
44	14	1	1	2026-09-07	13:00:00	14:00:00	2026-10-17 19:55:18.030609
45	15	1	2	2026-09-08	14:00:00	15:00:00	2026-10-17 19:55:18.030609
46	16	1	1	2026-09-09	15:00:00	16:00:00	2026-10-17 19:55:18.030609
47	17	1	2	2026-09-10	16:00:00	17:00:00	2026-10-17 19:55:18.030609
48	18	1	1	2026-09-11	17:00:00	18:00:00	2026-10-17 19:55:18.030609
49	19	1	2	2026-09-12	18:00:00	19:00:00	2026-10-17 19:55:18.030609
50	20	1	1	2026-09-13	19:00:00	20:00:00	2026-10-17 19:55:18.030609
52	30	3	2	2026-10-19	13:00:00	14:00:00	2026-10-18 19:46:07.767495
51	29	3	1	2026-10-19	13:00:00	14:00:00	2026-10-18 19:42:25.19921
53	30	1	1	2026-10-18	14:23:00	15:23:00	2026-10-18 20:23:10.40861
\.


--
-- Data for Name: terapeuta; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.terapeuta (id_terapeuta, id_usuario, id_estado_terapeuta, nombre, apellido_paterno, apellido_materno, cedula_profesional) FROM stdin;
1	2	1	Alejandro	Treviño	Salinas	CED10001
2	3	1	Mariana	Garza	García	CED10002
3	4	1	Roberto	Cantú	Lozano	CED10003
4	5	1	Sofía	Elizondo	Martínez	CED10004
5	6	1	Luis	Villarreal	Ríos	CED10005
6	7	1	Ana	Sada	Gómez	CED10006
7	8	1	Carlos	Morales	Pérez	CED10007
8	9	1	Elena	Rojas	Fernández	CED10008
9	10	1	Fernando	Herrera	Guzmán	CED10009
10	11	1	Patricia	Sepúlveda	Cárdenas	CED10010
11	50	1	Paola Fernanda	Taha	Garza	CED10487
\.


--
-- Data for Name: terapeuta_especialidad; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.terapeuta_especialidad (id_terapeuta, id_especialidad) FROM stdin;
\.


--
-- Data for Name: tipo_alerta; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.tipo_alerta (id_tipo_alerta, nombre, descripcion) FROM stdin;
\.


--
-- Data for Name: usuario; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.usuario (id_usuario, id_rol, id_estado_usuario, correo, password_hash, fecha_creacion, ultimo_acceso) FROM stdin;
2	2	1	terapeuta1@clinica.com	scrypt:32768:8:1$dummy$hash2	2026-10-17 19:55:18.010379	\N
3	2	1	terapeuta2@clinica.com	scrypt:32768:8:1$dummy$hash3	2026-10-17 19:55:18.010379	\N
4	2	1	terapeuta3@clinica.com	scrypt:32768:8:1$dummy$hash4	2026-10-17 19:55:18.010379	\N
5	2	1	terapeuta4@clinica.com	scrypt:32768:8:1$dummy$hash5	2026-10-17 19:55:18.010379	\N
6	2	1	terapeuta5@clinica.com	scrypt:32768:8:1$dummy$hash6	2026-10-17 19:55:18.010379	\N
7	2	1	terapeuta6@clinica.com	scrypt:32768:8:1$dummy$hash7	2026-10-17 19:55:18.010379	\N
8	2	1	terapeuta7@clinica.com	scrypt:32768:8:1$dummy$hash8	2026-10-17 19:55:18.010379	\N
9	2	1	terapeuta8@clinica.com	scrypt:32768:8:1$dummy$hash9	2026-10-17 19:55:18.010379	\N
10	2	1	terapeuta9@clinica.com	scrypt:32768:8:1$dummy$hash10	2026-10-17 19:55:18.010379	\N
11	2	1	terapeuta10@clinica.com	scrypt:32768:8:1$dummy$hash11	2026-10-17 19:55:18.010379	\N
12	3	1	paciente1@correo.com	scrypt:32768:8:1$dummy$hash12	2026-10-17 19:55:18.010379	\N
13	3	1	paciente2@correo.com	scrypt:32768:8:1$dummy$hash13	2026-10-17 19:55:18.010379	\N
14	3	1	paciente3@correo.com	scrypt:32768:8:1$dummy$hash14	2026-10-17 19:55:18.010379	\N
15	3	1	paciente4@correo.com	scrypt:32768:8:1$dummy$hash15	2026-10-17 19:55:18.010379	\N
16	3	1	paciente5@correo.com	scrypt:32768:8:1$dummy$hash16	2026-10-17 19:55:18.010379	\N
17	3	1	paciente6@correo.com	scrypt:32768:8:1$dummy$hash17	2026-10-17 19:55:18.010379	\N
18	3	1	paciente7@correo.com	scrypt:32768:8:1$dummy$hash18	2026-10-17 19:55:18.010379	\N
19	3	1	paciente8@correo.com	scrypt:32768:8:1$dummy$hash19	2026-10-17 19:55:18.010379	\N
20	3	1	paciente9@correo.com	scrypt:32768:8:1$dummy$hash20	2026-10-17 19:55:18.010379	\N
21	3	1	paciente10@correo.com	scrypt:32768:8:1$dummy$hash21	2026-10-17 19:55:18.010379	\N
22	3	1	paciente11@correo.com	scrypt:32768:8:1$dummy$hash22	2026-10-17 19:55:18.010379	\N
23	3	1	paciente12@correo.com	scrypt:32768:8:1$dummy$hash23	2026-10-17 19:55:18.010379	\N
24	3	1	paciente13@correo.com	scrypt:32768:8:1$dummy$hash24	2026-10-17 19:55:18.010379	\N
25	3	1	paciente14@correo.com	scrypt:32768:8:1$dummy$hash25	2026-10-17 19:55:18.010379	\N
26	3	1	paciente15@correo.com	scrypt:32768:8:1$dummy$hash26	2026-10-17 19:55:18.010379	\N
27	3	1	paciente16@correo.com	scrypt:32768:8:1$dummy$hash27	2026-10-17 19:55:18.010379	\N
28	3	1	paciente17@correo.com	scrypt:32768:8:1$dummy$hash28	2026-10-17 19:55:18.010379	\N
29	3	1	paciente18@correo.com	scrypt:32768:8:1$dummy$hash29	2026-10-17 19:55:18.010379	\N
30	3	1	paciente19@correo.com	scrypt:32768:8:1$dummy$hash30	2026-10-17 19:55:18.010379	\N
31	3	1	paciente20@correo.com	scrypt:32768:8:1$dummy$hash31	2026-10-17 19:55:18.010379	\N
32	3	1	paciente21@correo.com	scrypt:32768:8:1$dummy$hash32	2026-10-17 19:55:18.010379	\N
33	3	1	paciente22@correo.com	scrypt:32768:8:1$dummy$hash33	2026-10-17 19:55:18.010379	\N
34	3	1	paciente23@correo.com	scrypt:32768:8:1$dummy$hash34	2026-10-17 19:55:18.010379	\N
35	3	1	paciente24@correo.com	scrypt:32768:8:1$dummy$hash35	2026-10-17 19:55:18.010379	\N
36	3	1	paciente25@correo.com	scrypt:32768:8:1$dummy$hash36	2026-10-17 19:55:18.010379	\N
37	3	1	paciente26@correo.com	scrypt:32768:8:1$dummy$hash37	2026-10-17 19:55:18.010379	\N
38	3	1	paciente27@correo.com	scrypt:32768:8:1$dummy$hash38	2026-10-17 19:55:18.010379	\N
39	3	1	paciente28@correo.com	scrypt:32768:8:1$dummy$hash39	2026-10-17 19:55:18.010379	\N
40	3	1	paciente29@correo.com	scrypt:32768:8:1$dummy$hash40	2026-10-17 19:55:18.010379	\N
41	3	1	paciente30@correo.com	scrypt:32768:8:1$dummy$hash41	2026-10-17 19:55:18.010379	\N
42	3	2	paola.taha@gmail.com	ZeusFernando	2026-10-18 02:20:41.891364	\N
45	3	1	paola.tah@gmail.com	ZeusFernando	2026-10-18 02:35:54.020426	\N
46	2	1	zeus.fernando@gmail.com	Paolita	2026-10-18 03:05:44.988707	\N
47	3	1	ce_aguilar@hotmail.com	Maxito01	2026-10-18 03:08:25.882202	\N
1	1	1	admin@clinica.com	12345	2026-10-17 19:55:18.010379	\N
50	2	1	paola.terapeuta@clinica.com	12345	2026-10-18 22:07:13.917424	\N
51	3	1	carlos.paciente@clinica.com	12345	2026-10-18 23:06:25.68	\N
48	3	2	eduardo.aguilar@directlink.net.mx	Manchas.2015	2026-10-18 03:37:49.230778	\N
52	3	2	email@gmail.com	12345	2026-10-22 14:41:28.265484	\N
\.


--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.alerta_id_alerta_seq', 1, false);


--
-- Name: aplicacion_instrumento_id_aplicacion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.aplicacion_instrumento_id_aplicacion_seq', 1, false);


--
-- Name: asignacion_terapeuta_paciente_id_asignacion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.asignacion_terapeuta_paciente_id_asignacion_seq', 30, true);


--
-- Name: auditoria_id_auditoria_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.auditoria_id_auditoria_seq', 1, false);


--
-- Name: dimension_instrumento_id_dimension_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.dimension_instrumento_id_dimension_seq', 1, false);


--
-- Name: especialidad_id_especialidad_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.especialidad_id_especialidad_seq', 10, true);


--
-- Name: estado_asignacion_id_estado_asignacion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_asignacion_id_estado_asignacion_seq', 2, true);


--
-- Name: estado_objetivo_id_estado_objetivo_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_objetivo_id_estado_objetivo_seq', 2, true);


--
-- Name: estado_paciente_id_estado_paciente_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_paciente_id_estado_paciente_seq', 3, true);


--
-- Name: estado_plan_id_estado_plan_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_plan_id_estado_plan_seq', 2, true);


--
-- Name: estado_sesion_id_estado_sesion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_sesion_id_estado_sesion_seq', 3, true);


--
-- Name: estado_terapeuta_id_estado_terapeuta_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_terapeuta_id_estado_terapeuta_seq', 3, true);


--
-- Name: estado_usuario_id_estado_usuario_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.estado_usuario_id_estado_usuario_seq', 2, true);


--
-- Name: historial_objetivo_id_historial_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.historial_objetivo_id_historial_seq', 1, false);


--
-- Name: instrumento_id_instrumento_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.instrumento_id_instrumento_seq', 1, false);


--
-- Name: modalidad_sesion_id_modalidad_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.modalidad_sesion_id_modalidad_seq', 2, true);


--
-- Name: objetivo_id_objetivo_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.objetivo_id_objetivo_seq', 1, false);


--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.paciente_id_paciente_seq', 35, true);


--
-- Name: permiso_id_permiso_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.permiso_id_permiso_seq', 1, false);


--
-- Name: plan_terapeutico_id_plan_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.plan_terapeutico_id_plan_seq', 1, false);


--
-- Name: referencia_bitacora_id_referencia_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.referencia_bitacora_id_referencia_seq', 1, false);


--
-- Name: referencia_resumen_id_referencia_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.referencia_resumen_id_referencia_seq', 1, false);


--
-- Name: resultado_instrumento_id_resultado_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.resultado_instrumento_id_resultado_seq', 1, false);


--
-- Name: rol_id_rol_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.rol_id_rol_seq', 3, true);


--
-- Name: sesion_id_sesion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.sesion_id_sesion_seq', 53, true);


--
-- Name: terapeuta_id_terapeuta_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.terapeuta_id_terapeuta_seq', 11, true);


--
-- Name: tipo_alerta_id_tipo_alerta_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.tipo_alerta_id_tipo_alerta_seq', 1, false);


--
-- Name: usuario_id_usuario_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.usuario_id_usuario_seq', 52, true);


--
-- Name: alerta alerta_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_pkey PRIMARY KEY (id_alerta);


--
-- Name: aplicacion_instrumento aplicacion_instrumento_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.aplicacion_instrumento
    ADD CONSTRAINT aplicacion_instrumento_pkey PRIMARY KEY (id_aplicacion);


--
-- Name: asignacion_terapeuta_paciente asignacion_terapeuta_paciente_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente
    ADD CONSTRAINT asignacion_terapeuta_paciente_pkey PRIMARY KEY (id_asignacion);


--
-- Name: auditoria auditoria_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.auditoria
    ADD CONSTRAINT auditoria_pkey PRIMARY KEY (id_auditoria);


--
-- Name: dimension_instrumento dimension_instrumento_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.dimension_instrumento
    ADD CONSTRAINT dimension_instrumento_pkey PRIMARY KEY (id_dimension);


--
-- Name: especialidad especialidad_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.especialidad
    ADD CONSTRAINT especialidad_pkey PRIMARY KEY (id_especialidad);


--
-- Name: estado_asignacion estado_asignacion_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_asignacion
    ADD CONSTRAINT estado_asignacion_pkey PRIMARY KEY (id_estado_asignacion);


--
-- Name: estado_objetivo estado_objetivo_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_objetivo
    ADD CONSTRAINT estado_objetivo_pkey PRIMARY KEY (id_estado_objetivo);


--
-- Name: estado_paciente estado_paciente_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_paciente
    ADD CONSTRAINT estado_paciente_pkey PRIMARY KEY (id_estado_paciente);


--
-- Name: estado_plan estado_plan_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_plan
    ADD CONSTRAINT estado_plan_pkey PRIMARY KEY (id_estado_plan);


--
-- Name: estado_sesion estado_sesion_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_sesion
    ADD CONSTRAINT estado_sesion_pkey PRIMARY KEY (id_estado_sesion);


--
-- Name: estado_terapeuta estado_terapeuta_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_terapeuta
    ADD CONSTRAINT estado_terapeuta_pkey PRIMARY KEY (id_estado_terapeuta);


--
-- Name: estado_usuario estado_usuario_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.estado_usuario
    ADD CONSTRAINT estado_usuario_pkey PRIMARY KEY (id_estado_usuario);


--
-- Name: historial_objetivo historial_objetivo_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.historial_objetivo
    ADD CONSTRAINT historial_objetivo_pkey PRIMARY KEY (id_historial);


--
-- Name: instrumento instrumento_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.instrumento
    ADD CONSTRAINT instrumento_pkey PRIMARY KEY (id_instrumento);


--
-- Name: modalidad_sesion modalidad_sesion_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.modalidad_sesion
    ADD CONSTRAINT modalidad_sesion_pkey PRIMARY KEY (id_modalidad);


--
-- Name: objetivo objetivo_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.objetivo
    ADD CONSTRAINT objetivo_pkey PRIMARY KEY (id_objetivo);


--
-- Name: paciente paciente_id_usuario_key; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_id_usuario_key UNIQUE (id_usuario);


--
-- Name: paciente paciente_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_pkey PRIMARY KEY (id_paciente);


--
-- Name: permiso permiso_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.permiso
    ADD CONSTRAINT permiso_pkey PRIMARY KEY (id_permiso);


--
-- Name: plan_terapeutico plan_terapeutico_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.plan_terapeutico
    ADD CONSTRAINT plan_terapeutico_pkey PRIMARY KEY (id_plan);


--
-- Name: referencia_bitacora referencia_bitacora_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_bitacora
    ADD CONSTRAINT referencia_bitacora_pkey PRIMARY KEY (id_referencia);


--
-- Name: referencia_resumen referencia_resumen_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_resumen
    ADD CONSTRAINT referencia_resumen_pkey PRIMARY KEY (id_referencia);


--
-- Name: resultado_instrumento resultado_instrumento_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.resultado_instrumento
    ADD CONSTRAINT resultado_instrumento_pkey PRIMARY KEY (id_resultado);


--
-- Name: rol_permiso rol_permiso_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.rol_permiso
    ADD CONSTRAINT rol_permiso_pkey PRIMARY KEY (id_rol, id_permiso);


--
-- Name: rol rol_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.rol
    ADD CONSTRAINT rol_pkey PRIMARY KEY (id_rol);


--
-- Name: sesion sesion_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.sesion
    ADD CONSTRAINT sesion_pkey PRIMARY KEY (id_sesion);


--
-- Name: terapeuta terapeuta_cedula_profesional_key; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta
    ADD CONSTRAINT terapeuta_cedula_profesional_key UNIQUE (cedula_profesional);


--
-- Name: terapeuta_especialidad terapeuta_especialidad_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta_especialidad
    ADD CONSTRAINT terapeuta_especialidad_pkey PRIMARY KEY (id_terapeuta, id_especialidad);


--
-- Name: terapeuta terapeuta_id_usuario_key; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta
    ADD CONSTRAINT terapeuta_id_usuario_key UNIQUE (id_usuario);


--
-- Name: terapeuta terapeuta_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta
    ADD CONSTRAINT terapeuta_pkey PRIMARY KEY (id_terapeuta);


--
-- Name: tipo_alerta tipo_alerta_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.tipo_alerta
    ADD CONSTRAINT tipo_alerta_pkey PRIMARY KEY (id_tipo_alerta);


--
-- Name: usuario usuario_correo_key; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_correo_key UNIQUE (correo);


--
-- Name: usuario usuario_pkey; Type: CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_pkey PRIMARY KEY (id_usuario);


--
-- Name: alerta alerta_id_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_id_paciente_fkey FOREIGN KEY (id_paciente) REFERENCES public.paciente(id_paciente);


--
-- Name: alerta alerta_id_terapeuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_id_terapeuta_fkey FOREIGN KEY (id_terapeuta) REFERENCES public.terapeuta(id_terapeuta);


--
-- Name: alerta alerta_id_tipo_alerta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.alerta
    ADD CONSTRAINT alerta_id_tipo_alerta_fkey FOREIGN KEY (id_tipo_alerta) REFERENCES public.tipo_alerta(id_tipo_alerta);


--
-- Name: aplicacion_instrumento aplicacion_instrumento_id_instrumento_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.aplicacion_instrumento
    ADD CONSTRAINT aplicacion_instrumento_id_instrumento_fkey FOREIGN KEY (id_instrumento) REFERENCES public.instrumento(id_instrumento);


--
-- Name: aplicacion_instrumento aplicacion_instrumento_id_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.aplicacion_instrumento
    ADD CONSTRAINT aplicacion_instrumento_id_paciente_fkey FOREIGN KEY (id_paciente) REFERENCES public.paciente(id_paciente);


--
-- Name: aplicacion_instrumento aplicacion_instrumento_id_terapeuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.aplicacion_instrumento
    ADD CONSTRAINT aplicacion_instrumento_id_terapeuta_fkey FOREIGN KEY (id_terapeuta) REFERENCES public.terapeuta(id_terapeuta);


--
-- Name: asignacion_terapeuta_paciente asignacion_terapeuta_paciente_asignado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente
    ADD CONSTRAINT asignacion_terapeuta_paciente_asignado_por_fkey FOREIGN KEY (asignado_por) REFERENCES public.usuario(id_usuario);


--
-- Name: asignacion_terapeuta_paciente asignacion_terapeuta_paciente_id_estado_asignacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente
    ADD CONSTRAINT asignacion_terapeuta_paciente_id_estado_asignacion_fkey FOREIGN KEY (id_estado_asignacion) REFERENCES public.estado_asignacion(id_estado_asignacion);


--
-- Name: asignacion_terapeuta_paciente asignacion_terapeuta_paciente_id_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente
    ADD CONSTRAINT asignacion_terapeuta_paciente_id_paciente_fkey FOREIGN KEY (id_paciente) REFERENCES public.paciente(id_paciente);


--
-- Name: asignacion_terapeuta_paciente asignacion_terapeuta_paciente_id_terapeuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.asignacion_terapeuta_paciente
    ADD CONSTRAINT asignacion_terapeuta_paciente_id_terapeuta_fkey FOREIGN KEY (id_terapeuta) REFERENCES public.terapeuta(id_terapeuta);


--
-- Name: auditoria auditoria_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.auditoria
    ADD CONSTRAINT auditoria_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario) ON DELETE SET NULL;


--
-- Name: dimension_instrumento dimension_instrumento_id_instrumento_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.dimension_instrumento
    ADD CONSTRAINT dimension_instrumento_id_instrumento_fkey FOREIGN KEY (id_instrumento) REFERENCES public.instrumento(id_instrumento) ON DELETE CASCADE;


--
-- Name: historial_objetivo historial_objetivo_id_objetivo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.historial_objetivo
    ADD CONSTRAINT historial_objetivo_id_objetivo_fkey FOREIGN KEY (id_objetivo) REFERENCES public.objetivo(id_objetivo);


--
-- Name: historial_objetivo historial_objetivo_registrado_por_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.historial_objetivo
    ADD CONSTRAINT historial_objetivo_registrado_por_fkey FOREIGN KEY (registrado_por) REFERENCES public.usuario(id_usuario);


--
-- Name: objetivo objetivo_id_estado_objetivo_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.objetivo
    ADD CONSTRAINT objetivo_id_estado_objetivo_fkey FOREIGN KEY (id_estado_objetivo) REFERENCES public.estado_objetivo(id_estado_objetivo);


--
-- Name: objetivo objetivo_id_plan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.objetivo
    ADD CONSTRAINT objetivo_id_plan_fkey FOREIGN KEY (id_plan) REFERENCES public.plan_terapeutico(id_plan);


--
-- Name: paciente paciente_id_estado_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_id_estado_paciente_fkey FOREIGN KEY (id_estado_paciente) REFERENCES public.estado_paciente(id_estado_paciente);


--
-- Name: paciente paciente_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.paciente
    ADD CONSTRAINT paciente_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);


--
-- Name: plan_terapeutico plan_terapeutico_id_asignacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.plan_terapeutico
    ADD CONSTRAINT plan_terapeutico_id_asignacion_fkey FOREIGN KEY (id_asignacion) REFERENCES public.asignacion_terapeuta_paciente(id_asignacion);


--
-- Name: plan_terapeutico plan_terapeutico_id_estado_plan_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.plan_terapeutico
    ADD CONSTRAINT plan_terapeutico_id_estado_plan_fkey FOREIGN KEY (id_estado_plan) REFERENCES public.estado_plan(id_estado_plan);


--
-- Name: referencia_bitacora referencia_bitacora_id_paciente_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_bitacora
    ADD CONSTRAINT referencia_bitacora_id_paciente_fkey FOREIGN KEY (id_paciente) REFERENCES public.paciente(id_paciente);


--
-- Name: referencia_resumen referencia_resumen_id_sesion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.referencia_resumen
    ADD CONSTRAINT referencia_resumen_id_sesion_fkey FOREIGN KEY (id_sesion) REFERENCES public.sesion(id_sesion);


--
-- Name: resultado_instrumento resultado_instrumento_id_aplicacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.resultado_instrumento
    ADD CONSTRAINT resultado_instrumento_id_aplicacion_fkey FOREIGN KEY (id_aplicacion) REFERENCES public.aplicacion_instrumento(id_aplicacion);


--
-- Name: resultado_instrumento resultado_instrumento_id_dimension_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.resultado_instrumento
    ADD CONSTRAINT resultado_instrumento_id_dimension_fkey FOREIGN KEY (id_dimension) REFERENCES public.dimension_instrumento(id_dimension);


--
-- Name: rol_permiso rol_permiso_id_permiso_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.rol_permiso
    ADD CONSTRAINT rol_permiso_id_permiso_fkey FOREIGN KEY (id_permiso) REFERENCES public.permiso(id_permiso) ON DELETE CASCADE;


--
-- Name: rol_permiso rol_permiso_id_rol_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.rol_permiso
    ADD CONSTRAINT rol_permiso_id_rol_fkey FOREIGN KEY (id_rol) REFERENCES public.rol(id_rol) ON DELETE CASCADE;


--
-- Name: sesion sesion_id_asignacion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.sesion
    ADD CONSTRAINT sesion_id_asignacion_fkey FOREIGN KEY (id_asignacion) REFERENCES public.asignacion_terapeuta_paciente(id_asignacion);


--
-- Name: sesion sesion_id_estado_sesion_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.sesion
    ADD CONSTRAINT sesion_id_estado_sesion_fkey FOREIGN KEY (id_estado_sesion) REFERENCES public.estado_sesion(id_estado_sesion);


--
-- Name: sesion sesion_id_modalidad_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.sesion
    ADD CONSTRAINT sesion_id_modalidad_fkey FOREIGN KEY (id_modalidad) REFERENCES public.modalidad_sesion(id_modalidad);


--
-- Name: terapeuta_especialidad terapeuta_especialidad_id_especialidad_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta_especialidad
    ADD CONSTRAINT terapeuta_especialidad_id_especialidad_fkey FOREIGN KEY (id_especialidad) REFERENCES public.especialidad(id_especialidad) ON DELETE CASCADE;


--
-- Name: terapeuta_especialidad terapeuta_especialidad_id_terapeuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta_especialidad
    ADD CONSTRAINT terapeuta_especialidad_id_terapeuta_fkey FOREIGN KEY (id_terapeuta) REFERENCES public.terapeuta(id_terapeuta) ON DELETE CASCADE;


--
-- Name: terapeuta terapeuta_id_estado_terapeuta_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta
    ADD CONSTRAINT terapeuta_id_estado_terapeuta_fkey FOREIGN KEY (id_estado_terapeuta) REFERENCES public.estado_terapeuta(id_estado_terapeuta);


--
-- Name: terapeuta terapeuta_id_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.terapeuta
    ADD CONSTRAINT terapeuta_id_usuario_fkey FOREIGN KEY (id_usuario) REFERENCES public.usuario(id_usuario);


--
-- Name: usuario usuario_id_estado_usuario_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_id_estado_usuario_fkey FOREIGN KEY (id_estado_usuario) REFERENCES public.estado_usuario(id_estado_usuario);


--
-- Name: usuario usuario_id_rol_fkey; Type: FK CONSTRAINT; Schema: public; Owner: usuario
--

ALTER TABLE ONLY public.usuario
    ADD CONSTRAINT usuario_id_rol_fkey FOREIGN KEY (id_rol) REFERENCES public.rol(id_rol);


--
-- PostgreSQL database dump complete
--

\unrestrict eAgh38gE6xsFTLfAnP3ArlknTsrz3MJqY2Iu65H9y5Rl3X3MQXKSYL8xD9FC51r

