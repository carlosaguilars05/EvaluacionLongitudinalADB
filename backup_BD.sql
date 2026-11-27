--
-- PostgreSQL database dump
--

\restrict b0RyQd5Rs0NqKZJdXX8PgD8brGZijFtT3qV890peIAI8IlYODHWMoI64Ft7T35v

-- Dumped from database version 17.12
-- Dumped by pg_dump version 17.12

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_alerta_riesgo_instrumento(); Type: FUNCTION; Schema: public; Owner: usuario
--

CREATE FUNCTION public.fn_alerta_riesgo_instrumento() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_paciente integer;
    v_id_terapeuta integer;
    v_instrumento character varying(150);
    v_dimension character varying(100);
    v_id_tipo_alerta integer;
    v_desc text;
BEGIN
    -- Umbral clínico moderado-alto (>= 15 puntos en escala psicométrica simulada)
    IF NEW.puntuacion_bruta >= 15.00 THEN
        SELECT ai.id_paciente, ai.id_terapeuta, i.nombre
        INTO v_id_paciente, v_id_terapeuta, v_instrumento
        FROM public.aplicacion_instrumento ai
        JOIN public.instrumento i ON ai.id_instrumento = i.id_instrumento
        WHERE ai.id_aplicacion = NEW.id_aplicacion;

        SELECT nombre_dimension INTO v_dimension
        FROM public.dimension_instrumento
        WHERE id_dimension = NEW.id_dimension;

        SELECT id_tipo_alerta INTO v_id_tipo_alerta
        FROM public.tipo_alerta
        ORDER BY id_tipo_alerta ASC
        LIMIT 1;

        IF v_id_paciente IS NOT NULL AND v_id_terapeuta IS NOT NULL AND v_id_tipo_alerta IS NOT NULL THEN
            v_desc := format(
                'Puntuación elevada detectada automáticamente (%s pts) en %s — dimensión "%s" (aplicación #%s). Requiere revisión terapéutica.',
                NEW.puntuacion_bruta,
                COALESCE(v_instrumento, 'Instrumento'),
                COALESCE(v_dimension, 'General'),
                NEW.id_aplicacion
            );

            INSERT INTO public.alerta (id_paciente, id_terapeuta, id_tipo_alerta, descripcion, atendida)
            VALUES (v_id_paciente, v_id_terapeuta, v_id_tipo_alerta, v_desc, FALSE);
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_alerta_riesgo_instrumento() OWNER TO usuario;

--
-- Name: fn_auditoria_clinica(); Type: FUNCTION; Schema: public; Owner: usuario
--

CREATE FUNCTION public.fn_auditoria_clinica() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_usuario integer;
    v_ip character varying(45);
    v_modulo character varying(50);
    v_id_registro integer;
    v_row_json jsonb;
    v_pk_col text;
BEGIN
    v_modulo := COALESCE(TG_ARGV[0], TG_TABLE_NAME);
    v_pk_col := COALESCE(TG_ARGV[1], 'id_' || TG_TABLE_NAME);

    v_id_usuario := NULLIF(current_setting('app.current_user_id', true), '')::integer;
    v_ip := COALESCE(NULLIF(current_setting('app.client_ip', true), ''), '127.0.0.1');

    IF TG_OP = 'DELETE' THEN
        v_row_json := to_jsonb(OLD);
    ELSE
        v_row_json := to_jsonb(NEW);
    END IF;

    v_id_registro := NULLIF(v_row_json ->> v_pk_col, '')::integer;

    INSERT INTO public.auditoria (
        id_usuario,
        accion,
        modulo,
        nombre_tabla_afectada,
        id_registro,
        direccion_ip,
        resultado
    )
    VALUES (
        v_id_usuario,
        TG_OP,
        v_modulo,
        TG_TABLE_NAME,
        v_id_registro,
        v_ip,
        'EXITO'
    );

    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_auditoria_clinica() OWNER TO usuario;

--
-- Name: fn_progreso_reactivo_objetivo(); Type: FUNCTION; Schema: public; Owner: usuario
--

CREATE FUNCTION public.fn_progreso_reactivo_objetivo() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_plan integer;
    v_pendientes integer;
BEGIN
    IF NEW.porcentaje_avance_registrado >= 100.00 THEN
        UPDATE public.objetivo
        SET id_estado_objetivo = 2
        WHERE id_objetivo = NEW.id_objetivo
          AND id_estado_objetivo <> 2;

        SELECT id_plan INTO v_id_plan
        FROM public.objetivo
        WHERE id_objetivo = NEW.id_objetivo;

        IF v_id_plan IS NOT NULL THEN
            SELECT COUNT(*) INTO v_pendientes
            FROM public.objetivo
            WHERE id_plan = v_id_plan
              AND id_estado_objetivo <> 2;

            IF v_pendientes = 0 THEN
                UPDATE public.plan_terapeutico
                SET id_estado_plan = 2,
                    fecha_fin = COALESCE(fecha_fin, CURRENT_DATE)
                WHERE id_plan = v_id_plan
                  AND id_estado_plan <> 2;
            END IF;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_progreso_reactivo_objetivo() OWNER TO usuario;

--
-- Name: fn_validar_sesion_integridad(); Type: FUNCTION; Schema: public; Owner: usuario
--

CREATE FUNCTION public.fn_validar_sesion_integridad() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_id_terapeuta integer;
    v_estado_asignacion integer;
    v_conflictos integer;
BEGIN
    IF NEW.hora_fin <= NEW.hora_inicio THEN
        RAISE EXCEPTION 'Integridad horaria: hora_fin (%) debe ser posterior a hora_inicio (%).',
            NEW.hora_fin, NEW.hora_inicio;
    END IF;

    SELECT id_terapeuta, id_estado_asignacion
    INTO v_id_terapeuta, v_estado_asignacion
    FROM public.asignacion_terapeuta_paciente
    WHERE id_asignacion = NEW.id_asignacion;

    IF v_id_terapeuta IS NULL THEN
        RAISE EXCEPTION 'Asignación clínica % inexistente.', NEW.id_asignacion;
    END IF;

    IF TG_OP = 'INSERT' AND v_estado_asignacion <> 1 THEN
        RAISE EXCEPTION 'No se puede agendar sesión sobre una asignación finalizada (id_asignacion=%).',
            NEW.id_asignacion;
    END IF;

    IF NEW.id_estado_sesion = 1 THEN
        SELECT COUNT(*) INTO v_conflictos
        FROM public.sesion s
        JOIN public.asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        WHERE a.id_terapeuta = v_id_terapeuta
          AND s.fecha = NEW.fecha
          AND s.id_estado_sesion = 1
          AND s.id_sesion <> COALESCE(NEW.id_sesion, -1)
          AND (NEW.hora_inicio < s.hora_fin AND NEW.hora_fin > s.hora_inicio);

        IF v_conflictos > 0 THEN
            RAISE EXCEPTION 'Empalme de horario detectado por trigger para el terapeuta % en fecha %.',
                v_id_terapeuta, NEW.fecha;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.fn_validar_sesion_integridad() OWNER TO usuario;

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
-- Name: sp_actualizar_password_usuario(integer, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_actualizar_password_usuario(IN p_id_usuario integer, IN p_password_hash character varying, OUT p_mensaje character varying)
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
-- Name: sp_asignar_instrumento(integer, integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_asignar_instrumento(IN p_id_instrumento integer, IN p_id_paciente integer, IN p_id_terapeuta integer, OUT p_id_aplicacion integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_asignado integer;
BEGIN
    SELECT COUNT(*) INTO v_asignado
    FROM public.asignacion_terapeuta_paciente
    WHERE id_paciente = p_id_paciente
      AND id_terapeuta = p_id_terapeuta
      AND id_estado_asignacion = 1;

    IF v_asignado = 0 THEN
        p_id_aplicacion := NULL;
        p_mensaje := 'Acceso denegado: solo puedes asignar instrumentos a tus pacientes vigentes.';
        RETURN;
    END IF;

    INSERT INTO public.aplicacion_instrumento (id_instrumento, id_paciente, id_terapeuta, estado)
    VALUES (p_id_instrumento, p_id_paciente, p_id_terapeuta, 'Pendiente')
    RETURNING id_aplicacion INTO p_id_aplicacion;

    p_mensaje := 'Cuestionario asignado correctamente al paciente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_aplicacion := NULL;
        p_mensaje := 'Error al asignar instrumento: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_asignar_instrumento(IN p_id_instrumento integer, IN p_id_paciente integer, IN p_id_terapeuta integer, OUT p_id_aplicacion integer, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_atender_alerta(integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_atender_alerta(IN p_id_alerta integer, IN p_id_terapeuta integer, OUT p_atendida boolean, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_filas integer;
BEGIN
    UPDATE public.alerta
    SET atendida = TRUE
    WHERE id_alerta = p_id_alerta
      AND atendida = FALSE
      AND (p_id_terapeuta IS NULL OR id_terapeuta = p_id_terapeuta);

    GET DIAGNOSTICS v_filas = ROW_COUNT;

    IF v_filas > 0 THEN
        p_atendida := TRUE;
        p_mensaje := 'Alerta marcada como atendida correctamente.';
    ELSE
        p_atendida := FALSE;
        p_mensaje := 'No se pudo atender la alerta (inexistente, ya atendida o sin permiso).';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_atendida := FALSE;
        p_mensaje := 'Error al atender la alerta: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_atender_alerta(IN p_id_alerta integer, IN p_id_terapeuta integer, OUT p_atendida boolean, OUT p_mensaje character varying) OWNER TO usuario;

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
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al recuperar agenda del paciente: ' || SQLERRM;
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
-- Name: sp_consultar_alertas_activas(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_alertas_activas(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_id_terapeuta IS NULL THEN
        OPEN p_cursor FOR
            SELECT id_alerta, tipo_alerta, descripcion, paciente, terapeuta_notificado, fecha_generacion
            FROM public.vw_alertas_activas;
    ELSE
        OPEN p_cursor FOR
            SELECT v.id_alerta, v.tipo_alerta, v.descripcion, v.paciente,
                   v.terapeuta_notificado, v.fecha_generacion
            FROM public.vw_alertas_activas v
            JOIN public.alerta a ON v.id_alerta = a.id_alerta
            WHERE a.id_terapeuta = p_id_terapeuta
            ORDER BY v.fecha_generacion DESC;
    END IF;

    p_mensaje := 'Alertas activas recuperadas desde vw_alertas_activas.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar alertas activas: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_alertas_activas(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_aplicaciones_instrumentos(integer, integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_aplicaciones_instrumentos(IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            ai.id_aplicacion,
            ai.id_instrumento,
            i.nombre AS instrumento,
            ai.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            ai.fecha_asignacion,
            ai.fecha_respuesta,
            COALESCE(ai.estado, 'Pendiente') AS estado,
            ai.id_documento_mongo
        FROM public.aplicacion_instrumento ai
        JOIN public.instrumento i ON ai.id_instrumento = i.id_instrumento
        JOIN public.paciente p ON ai.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON ai.id_terapeuta = t.id_terapeuta
        WHERE (p_id_terapeuta IS NULL OR ai.id_terapeuta = p_id_terapeuta)
          AND (p_id_paciente IS NULL OR ai.id_paciente = p_id_paciente)
        ORDER BY
            CASE WHEN COALESCE(ai.estado, 'Pendiente') = 'Pendiente' THEN 0 ELSE 1 END,
            ai.fecha_asignacion DESC,
            ai.id_aplicacion DESC;

    p_mensaje := 'Aplicaciones de instrumentos recuperadas.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar aplicaciones: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_aplicaciones_instrumentos(IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_asignaciones_terapeuta(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_asignaciones_terapeuta(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
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
-- Name: sp_consultar_auditoria(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_auditoria(IN p_limite integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_auditoria, fecha_hora, usuario_responsable, accion, modulo,
               nombre_tabla_afectada, direccion_ip, resultado
        FROM public.vw_reporte_auditoria
        LIMIT COALESCE(NULLIF(p_limite, 0), 100);

    p_mensaje := 'Bitácora de auditoría recuperada desde vw_reporte_auditoria.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar auditoría: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_auditoria(IN p_limite integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_directorio_pacientes(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_directorio_pacientes(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_paciente, nombre_completo, telefono, correo, estatus_cuenta, fecha_registro
        FROM public.vw_directorio_pacientes
        ORDER BY id_paciente ASC;

    p_mensaje := 'Directorio de pacientes recuperado desde vw_directorio_pacientes.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar vw_directorio_pacientes: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_directorio_pacientes(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_directorio_terapeutas(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_directorio_terapeutas(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_terapeuta, nombre_terapeuta, cedula_profesional,
               COALESCE(especialidades, 'Sin especialidad asignada') AS especialidades,
               estatus
        FROM public.vw_directorio_terapeutas
        ORDER BY nombre_terapeuta ASC;

    p_mensaje := 'Directorio de terapeutas recuperado desde vw_directorio_terapeutas.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar vw_directorio_terapeutas: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_directorio_terapeutas(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_consultar_objetivos_de_plan(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_objetivos_de_plan(IN p_id_plan integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        WITH ultimo_hist AS (
            SELECT DISTINCT ON (id_objetivo)
                id_objetivo,
                porcentaje_avance_registrado,
                fecha_registro,
                comentario
            FROM public.historial_objetivo
            ORDER BY id_objetivo, fecha_registro DESC, id_historial DESC
        )
        SELECT
            o.id_objetivo,
            o.nombre,
            COALESCE(o.descripcion, '') AS descripcion,
            eo.nombre AS estado_objetivo,
            o.fecha_inicio,
            o.fecha_meta,
            COALESCE(uh.porcentaje_avance_registrado, 0.00) AS ultimo_porcentaje,
            uh.fecha_registro AS ultima_fecha,
            COALESCE(uh.comentario, 'Sin avances registrados aún') AS ultimo_comentario
        FROM public.objetivo o
        JOIN public.estado_objetivo eo ON o.id_estado_objetivo = eo.id_estado_objetivo
        LEFT JOIN ultimo_hist uh ON o.id_objetivo = uh.id_objetivo
        WHERE o.id_plan = p_id_plan
        ORDER BY o.id_estado_objetivo ASC, o.id_objetivo ASC;

    p_mensaje := 'Objetivos del plan recuperados correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar objetivos del plan: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_objetivos_de_plan(IN p_id_plan integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_consultar_planes_terapeuticos(integer, integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_planes_terapeuticos(IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            pt.id_plan,
            pt.id_asignacion,
            a.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            ep.nombre AS estado_plan,
            pt.fecha_inicio,
            pt.fecha_fin,
            COALESCE(pt.descripcion_general, '') AS descripcion_general,
            COUNT(o.id_objetivo) AS total_objetivos,
            COUNT(CASE WHEN o.id_estado_objetivo = 2 THEN 1 END) AS logrados
        FROM public.plan_terapeutico pt
        JOIN public.estado_plan ep ON pt.id_estado_plan = ep.id_estado_plan
        JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
        JOIN public.paciente p ON a.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
        LEFT JOIN public.objetivo o ON pt.id_plan = o.id_plan
        WHERE (p_id_terapeuta IS NULL OR a.id_terapeuta = p_id_terapeuta)
          AND (p_id_paciente IS NULL OR a.id_paciente = p_id_paciente)
        GROUP BY pt.id_plan, pt.id_asignacion, a.id_paciente, p.nombre, p.apellido_paterno,
                 t.nombre, t.apellido_paterno, ep.nombre, pt.fecha_inicio, pt.fecha_fin, pt.descripcion_general
        ORDER BY pt.id_estado_plan ASC, pt.fecha_inicio DESC, pt.id_plan DESC;

    p_mensaje := 'Planes terapéuticos recuperados correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar planes terapéuticos: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_planes_terapeuticos(IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_progreso_clinico(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_progreso_clinico(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_id_terapeuta IS NULL THEN
        OPEN p_cursor FOR
            SELECT paciente, objetivo_terapeutico, estado_objetivo,
                   COALESCE(avance_actual, 0.00) AS avance_actual,
                   ultima_actualizacion, COALESCE(comentario, 'Sin comentarios') AS comentario
            FROM public.vw_progreso_clinico
            ORDER BY paciente ASC, objetivo_terapeutico ASC;
    ELSE
        OPEN p_cursor FOR
            SELECT DISTINCT v.paciente, v.objetivo_terapeutico, v.estado_objetivo,
                   COALESCE(v.avance_actual, 0.00) AS avance_actual,
                   v.ultima_actualizacion, COALESCE(v.comentario, 'Sin comentarios') AS comentario
            FROM public.vw_progreso_clinico v
            JOIN public.objetivo o ON o.nombre = v.objetivo_terapeutico
            JOIN public.plan_terapeutico pt ON o.id_plan = pt.id_plan
            JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
            WHERE a.id_terapeuta = p_id_terapeuta
            ORDER BY v.paciente ASC, v.objetivo_terapeutico ASC;
    END IF;

    p_mensaje := 'Progreso clínico recuperado desde vw_progreso_clinico.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar progreso clínico: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_progreso_clinico(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_consultar_resultados_instrumentos(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_consultar_resultados_instrumentos(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_id_terapeuta IS NULL THEN
        OPEN p_cursor FOR
            SELECT id_aplicacion, instrumento, paciente, dimension_evaluada,
                   puntuacion_bruta, fecha_respuesta
            FROM public.vw_resultados_instrumentos;
    ELSE
        OPEN p_cursor FOR
            SELECT v.id_aplicacion, v.instrumento, v.paciente, v.dimension_evaluada,
                   v.puntuacion_bruta, v.fecha_respuesta
            FROM public.vw_resultados_instrumentos v
            JOIN public.aplicacion_instrumento ai ON v.id_aplicacion = ai.id_aplicacion
            WHERE ai.id_terapeuta = p_id_terapeuta
            ORDER BY v.fecha_respuesta DESC;
    END IF;

    p_mensaje := 'Resultados de instrumentos recuperados desde vw_resultados_instrumentos.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al consultar resultados de instrumentos: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_consultar_resultados_instrumentos(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_crear_objetivo(integer, character varying, text, date, date); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_crear_objetivo(IN p_id_plan integer, IN p_nombre character varying, IN p_descripcion text, IN p_fecha_inicio date, IN p_fecha_meta date, OUT p_id_objetivo integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO public.objetivo (id_plan, id_estado_objetivo, nombre, descripcion, fecha_inicio, fecha_meta)
    VALUES (p_id_plan, 1, p_nombre, p_descripcion, COALESCE(p_fecha_inicio, CURRENT_DATE), p_fecha_meta)
    RETURNING id_objetivo INTO p_id_objetivo;

    -- Si el plan estaba completado, al agregar un objetivo pendiente vuelve a Activo
    UPDATE public.plan_terapeutico
    SET id_estado_plan = 1, fecha_fin = NULL
    WHERE id_plan = p_id_plan AND id_estado_plan = 2;

    p_mensaje := 'Objetivo terapéutico agregado correctamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_objetivo := NULL;
        p_mensaje := 'Error al crear objetivo: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_crear_objetivo(IN p_id_plan integer, IN p_nombre character varying, IN p_descripcion text, IN p_fecha_inicio date, IN p_fecha_meta date, OUT p_id_objetivo integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_crear_plan_terapeutico(integer, date, text); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_crear_plan_terapeutico(IN p_id_asignacion integer, IN p_fecha_inicio date, IN p_descripcion text, OUT p_id_plan integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO public.plan_terapeutico (id_asignacion, id_estado_plan, fecha_inicio, descripcion_general)
    VALUES (p_id_asignacion, 1, COALESCE(p_fecha_inicio, CURRENT_DATE), p_descripcion)
    RETURNING id_plan INTO p_id_plan;

    p_mensaje := 'Plan terapéutico creado exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_plan := NULL;
        p_mensaje := 'Error al crear plan terapéutico: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_crear_plan_terapeutico(IN p_id_asignacion integer, IN p_fecha_inicio date, IN p_descripcion text, OUT p_id_plan integer, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_establecer_contexto_auditoria(integer, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_establecer_contexto_auditoria(IN p_id_usuario integer, IN p_ip character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM set_config('app.current_user_id', COALESCE(p_id_usuario::text, ''), true);
    PERFORM set_config('app.client_ip', COALESCE(p_ip, '127.0.0.1'), true);
    p_mensaje := 'Contexto de auditoría configurado.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al configurar contexto de auditoría: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_establecer_contexto_auditoria(IN p_id_usuario integer, IN p_ip character varying, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_aplicaciones_seed_mongo(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_aplicaciones_seed_mongo(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            ai.id_aplicacion,
            ai.id_instrumento,
            i.nombre AS instrumento,
            ai.id_paciente,
            ai.id_terapeuta,
            ai.fecha_respuesta,
            ai.id_documento_mongo
        FROM public.aplicacion_instrumento ai
        JOIN public.instrumento i ON ai.id_instrumento = i.id_instrumento
        ORDER BY ai.id_aplicacion ASC;

    p_mensaje := 'Aplicaciones listadas para sincronización con MongoDB.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar aplicaciones: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_aplicaciones_seed_mongo(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_instrumentos_activos(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_instrumentos_activos(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_instrumento, nombre, COALESCE(descripcion, ''), COALESCE(version, 'v1.0')
        FROM public.instrumento
        WHERE COALESCE(estado, 'Activo') = 'Activo'
        ORDER BY id_instrumento ASC;

    p_mensaje := 'Instrumentos activos recuperados.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar instrumentos: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_instrumentos_activos(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_listar_referencias_bitacora(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_referencias_bitacora(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT id_referencia, id_paciente, fecha_registro, id_documento_mongo
        FROM public.referencia_bitacora
        WHERE id_paciente = p_id_paciente
        ORDER BY fecha_registro DESC;

    p_mensaje := 'Referencias de bitácoras recuperadas.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar referencias de bitácora: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_referencias_bitacora(IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_referencias_resumen(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_referencias_resumen(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            rr.id_referencia,
            rr.id_sesion,
            rr.fecha_creacion,
            rr.id_documento_mongo,
            a.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            s.fecha AS fecha_sesion
        FROM public.referencia_resumen rr
        JOIN public.sesion s ON rr.id_sesion = s.id_sesion
        JOIN public.asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        JOIN public.paciente p ON a.id_paciente = p.id_paciente
        WHERE (p_id_terapeuta IS NULL OR a.id_terapeuta = p_id_terapeuta)
        ORDER BY s.fecha DESC, rr.fecha_creacion DESC;

    p_mensaje := 'Referencias de resúmenes SOAP recuperadas.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar referencias de resúmenes: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_referencias_resumen(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_resultados_de_aplicacion(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_resultados_de_aplicacion(IN p_id_aplicacion integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            ri.id_dimension,
            di.nombre_dimension,
            ri.puntuacion_bruta
        FROM public.resultado_instrumento ri
        JOIN public.dimension_instrumento di ON ri.id_dimension = di.id_dimension
        WHERE ri.id_aplicacion = p_id_aplicacion
        ORDER BY ri.id_dimension ASC;

    p_mensaje := 'Resultados de aplicación recuperados.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar resultados de aplicación: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_resultados_de_aplicacion(IN p_id_aplicacion integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_sesiones_completadas_seed_mongo(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_sesiones_completadas_seed_mongo(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    OPEN p_cursor FOR
        SELECT
            s.id_sesion,
            a.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            a.id_terapeuta,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            s.fecha,
            m.nombre AS modalidad,
            rr.id_documento_mongo
        FROM public.sesion s
        JOIN public.asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        JOIN public.paciente p ON a.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
        JOIN public.modalidad_sesion m ON s.id_modalidad = m.id_modalidad
        LEFT JOIN public.referencia_resumen rr ON s.id_sesion = rr.id_sesion
        WHERE s.id_estado_sesion = 2
        ORDER BY s.fecha DESC, s.id_sesion ASC;

    p_mensaje := 'Sesiones completadas recuperadas para sincronización SOAP.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al listar sesiones completadas: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_listar_sesiones_completadas_seed_mongo(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_listar_usuarios_para_migracion(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_listar_usuarios_para_migracion(INOUT p_cursor refcursor, OUT p_mensaje character varying)
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

--
-- Name: sp_obtener_aplicacion_detalle(integer, integer, integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_aplicacion_detalle(IN p_id_aplicacion integer, IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existe integer;
BEGIN
    SELECT COUNT(*) INTO v_existe
    FROM public.aplicacion_instrumento ai
    WHERE ai.id_aplicacion = p_id_aplicacion
      AND (p_id_terapeuta IS NULL OR ai.id_terapeuta = p_id_terapeuta)
      AND (p_id_paciente IS NULL OR ai.id_paciente = p_id_paciente);

    IF v_existe = 0 THEN
        p_autorizado := FALSE;
        p_mensaje := 'Acceso denegado o aplicación no encontrada.';
        OPEN p_cursor FOR SELECT NULL::integer WHERE FALSE;
        RETURN;
    END IF;

    p_autorizado := TRUE;
    OPEN p_cursor FOR
        SELECT
            ai.id_aplicacion,
            ai.id_instrumento,
            i.nombre AS instrumento,
            ai.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            ai.id_terapeuta,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            COALESCE(ai.estado, 'Pendiente') AS estado,
            ai.id_documento_mongo,
            ai.fecha_asignacion,
            ai.fecha_respuesta
        FROM public.aplicacion_instrumento ai
        JOIN public.instrumento i ON ai.id_instrumento = i.id_instrumento
        JOIN public.paciente p ON ai.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON ai.id_terapeuta = t.id_terapeuta
        WHERE ai.id_aplicacion = p_id_aplicacion;

    p_mensaje := 'Detalle de aplicación recuperado.';
EXCEPTION
    WHEN OTHERS THEN
        p_autorizado := FALSE;
        p_mensaje := 'Error al consultar aplicación: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_aplicacion_detalle(IN p_id_aplicacion integer, IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_obtener_detalle_sesion(integer, integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_detalle_sesion(IN p_id_sesion integer, IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existe integer;
BEGIN
    SELECT COUNT(*) INTO v_existe
    FROM public.sesion s
    JOIN public.asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
    WHERE s.id_sesion = p_id_sesion
      AND (p_id_terapeuta IS NULL OR a.id_terapeuta = p_id_terapeuta);

    IF v_existe = 0 THEN
        p_autorizado := FALSE;
        p_mensaje := 'Acceso denegado o sesión no encontrada.';
        OPEN p_cursor FOR SELECT NULL::integer WHERE FALSE;
        RETURN;
    END IF;

    p_autorizado := TRUE;
    OPEN p_cursor FOR
        SELECT
            s.id_sesion,
            s.fecha,
            s.hora_inicio,
            s.hora_fin,
            m.nombre AS modalidad,
            es.nombre AS estado_sesion,
            a.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            a.id_terapeuta,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            rr.id_documento_mongo
        FROM public.sesion s
        JOIN public.modalidad_sesion m ON s.id_modalidad = m.id_modalidad
        JOIN public.estado_sesion es ON s.id_estado_sesion = es.id_estado_sesion
        JOIN public.asignacion_terapeuta_paciente a ON s.id_asignacion = a.id_asignacion
        JOIN public.paciente p ON a.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
        LEFT JOIN public.referencia_resumen rr ON s.id_sesion = rr.id_sesion
        WHERE s.id_sesion = p_id_sesion;

    p_mensaje := 'Detalle de sesión recuperado.';
EXCEPTION
    WHEN OTHERS THEN
        p_autorizado := FALSE;
        p_mensaje := 'Error al consultar detalle de sesión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_detalle_sesion(IN p_id_sesion integer, IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_obtener_plan_detalle(integer, integer, integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_obtener_plan_detalle(IN p_id_plan integer, IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_existe integer;
BEGIN
    SELECT COUNT(*) INTO v_existe
    FROM public.plan_terapeutico pt
    JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
    WHERE pt.id_plan = p_id_plan
      AND (p_id_terapeuta IS NULL OR a.id_terapeuta = p_id_terapeuta)
      AND (p_id_paciente IS NULL OR a.id_paciente = p_id_paciente);

    IF v_existe = 0 THEN
        p_autorizado := FALSE;
        p_mensaje := 'Acceso denegado o plan terapéutico no encontrado.';
        OPEN p_cursor FOR SELECT NULL::integer WHERE FALSE;
        RETURN;
    END IF;

    p_autorizado := TRUE;
    OPEN p_cursor FOR
        SELECT
            pt.id_plan,
            pt.id_asignacion,
            a.id_paciente,
            p.nombre || ' ' || p.apellido_paterno AS paciente,
            t.nombre || ' ' || t.apellido_paterno AS terapeuta,
            ep.nombre AS estado_plan,
            pt.fecha_inicio,
            pt.fecha_fin,
            COALESCE(pt.descripcion_general, '') AS descripcion_general
        FROM public.plan_terapeutico pt
        JOIN public.estado_plan ep ON pt.id_estado_plan = ep.id_estado_plan
        JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
        JOIN public.paciente p ON a.id_paciente = p.id_paciente
        JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
        WHERE pt.id_plan = p_id_plan;

    p_mensaje := 'Detalle del plan recuperado.';
EXCEPTION
    WHEN OTHERS THEN
        p_autorizado := FALSE;
        p_mensaje := 'Error al consultar detalle del plan: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_obtener_plan_detalle(IN p_id_plan integer, IN p_id_terapeuta integer, IN p_id_paciente integer, INOUT p_cursor refcursor, OUT p_autorizado boolean, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_registrar_acceso_usuario(integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_acceso_usuario(IN p_id_usuario integer, OUT p_mensaje character varying)
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
-- Name: sp_registrar_referencia_bitacora(integer, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_referencia_bitacora(IN p_id_paciente integer, IN p_id_documento_mongo character varying, OUT p_id_referencia integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_referencia INTO p_id_referencia
    FROM public.referencia_bitacora
    WHERE id_documento_mongo = p_id_documento_mongo
    LIMIT 1;

    IF p_id_referencia IS NOT NULL THEN
        p_mensaje := 'Referencia de bitácora ya existente.';
        RETURN;
    END IF;

    INSERT INTO public.referencia_bitacora (id_paciente, id_documento_mongo)
    VALUES (p_id_paciente, p_id_documento_mongo)
    RETURNING id_referencia INTO p_id_referencia;

    p_mensaje := 'Referencia de bitácora registrada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_referencia := NULL;
        p_mensaje := 'Error al registrar referencia de bitácora: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_referencia_bitacora(IN p_id_paciente integer, IN p_id_documento_mongo character varying, OUT p_id_referencia integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_registrar_referencia_resumen(integer, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_referencia_resumen(IN p_id_sesion integer, IN p_id_documento_mongo character varying, OUT p_id_referencia integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT id_referencia INTO p_id_referencia
    FROM public.referencia_resumen
    WHERE id_sesion = p_id_sesion
    LIMIT 1;

    IF p_id_referencia IS NOT NULL THEN
        UPDATE public.referencia_resumen
        SET id_documento_mongo = p_id_documento_mongo,
            fecha_creacion = CURRENT_TIMESTAMP
        WHERE id_referencia = p_id_referencia;

        p_mensaje := 'Referencia de resumen SOAP actualizada.';
        RETURN;
    END IF;

    INSERT INTO public.referencia_resumen (id_sesion, id_documento_mongo)
    VALUES (p_id_sesion, p_id_documento_mongo)
    RETURNING id_referencia INTO p_id_referencia;

    p_mensaje := 'Referencia de resumen SOAP registrada exitosamente.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_referencia := NULL;
        p_mensaje := 'Error al registrar referencia de resumen: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_referencia_resumen(IN p_id_sesion integer, IN p_id_documento_mongo character varying, OUT p_id_referencia integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_registrar_resultado_dimension(integer, integer, numeric); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_registrar_resultado_dimension(IN p_id_aplicacion integer, IN p_id_dimension integer, IN p_puntuacion numeric, OUT p_id_resultado integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO public.resultado_instrumento (id_aplicacion, id_dimension, puntuacion_bruta)
    VALUES (p_id_aplicacion, p_id_dimension, p_puntuacion)
    RETURNING id_resultado INTO p_id_resultado;

    p_mensaje := 'Resultado numérico registrado.';
EXCEPTION
    WHEN OTHERS THEN
        p_id_resultado := NULL;
        p_mensaje := 'Error al registrar resultado de dimensión: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_registrar_resultado_dimension(IN p_id_aplicacion integer, IN p_id_dimension integer, IN p_puntuacion numeric, OUT p_id_resultado integer, OUT p_mensaje character varying) OWNER TO usuario;

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
-- Name: sp_reporte_avance_planes(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_reporte_avance_planes(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.tmp_avance_planes;

    CREATE TEMP TABLE tmp_avance_planes (
        id_plan integer,
        paciente text,
        terapeuta text,
        estado_plan character varying(50),
        total_objetivos integer,
        objetivos_logrados integer,
        promedio_avance numeric(5,2),
        fecha_inicio date
    ) ON COMMIT DROP;

    INSERT INTO tmp_avance_planes
    WITH ultimo_historial AS (
        SELECT DISTINCT ON (id_objetivo)
            id_objetivo,
            porcentaje_avance_registrado
        FROM public.historial_objetivo
        ORDER BY id_objetivo, fecha_registro DESC
    )
    SELECT
        pt.id_plan,
        p.nombre || ' ' || p.apellido_paterno AS paciente,
        t.nombre || ' ' || t.apellido_paterno AS terapeuta,
        ep.nombre AS estado_plan,
        COUNT(o.id_objetivo) AS total_objetivos,
        COUNT(CASE WHEN o.id_estado_objetivo = 2 THEN 1 END) AS objetivos_logrados,
        ROUND(COALESCE(AVG(COALESCE(uh.porcentaje_avance_registrado, 0)), 0), 2) AS promedio_avance,
        pt.fecha_inicio
    FROM public.plan_terapeutico pt
    JOIN public.estado_plan ep ON pt.id_estado_plan = ep.id_estado_plan
    JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
    JOIN public.paciente p ON a.id_paciente = p.id_paciente
    JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
    LEFT JOIN public.objetivo o ON pt.id_plan = o.id_plan
    LEFT JOIN ultimo_historial uh ON o.id_objetivo = uh.id_objetivo
    WHERE (p_id_terapeuta IS NULL OR a.id_terapeuta = p_id_terapeuta)
    GROUP BY pt.id_plan, p.nombre, p.apellido_paterno, t.nombre, t.apellido_paterno, ep.nombre, pt.fecha_inicio;

    OPEN p_cursor FOR
        SELECT
            id_plan,
            paciente,
            terapeuta,
            estado_plan,
            total_objetivos,
            objetivos_logrados,
            promedio_avance,
            fecha_inicio
        FROM tmp_avance_planes
        ORDER BY promedio_avance DESC, id_plan ASC;

    p_mensaje := 'Avance de planes terapéuticos consolidado mediante tabla temporal.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en sp_reporte_avance_planes: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_reporte_avance_planes(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_reporte_evolucion_longitudinal(integer, refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_reporte_evolucion_longitudinal(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.tmp_evolucion_longitudinal;

    CREATE TEMP TABLE tmp_evolucion_longitudinal (
        id_paciente integer,
        paciente text,
        instrumento character varying(150),
        dimension character varying(100),
        fecha_respuesta timestamp without time zone,
        puntuacion numeric(10,2),
        puntuacion_previa numeric(10,2),
        delta_cambio numeric(10,2),
        promedio_historico numeric(10,2)
    ) ON COMMIT DROP;

    INSERT INTO tmp_evolucion_longitudinal
    SELECT
        ai.id_paciente,
        v.paciente,
        v.instrumento,
        v.dimension_evaluada,
        v.fecha_respuesta,
        v.puntuacion_bruta,
        LAG(v.puntuacion_bruta) OVER (
            PARTITION BY ai.id_paciente, v.instrumento, v.dimension_evaluada
            ORDER BY v.fecha_respuesta ASC
        ) AS puntuacion_previa,
        v.puntuacion_bruta - LAG(v.puntuacion_bruta) OVER (
            PARTITION BY ai.id_paciente, v.instrumento, v.dimension_evaluada
            ORDER BY v.fecha_respuesta ASC
        ) AS delta_cambio,
        ROUND(
            AVG(v.puntuacion_bruta) OVER (
                PARTITION BY ai.id_paciente, v.instrumento, v.dimension_evaluada
            ),
            2
        ) AS promedio_historico
    FROM public.vw_resultados_instrumentos v
    JOIN public.aplicacion_instrumento ai ON v.id_aplicacion = ai.id_aplicacion
    WHERE (p_id_terapeuta IS NULL OR ai.id_terapeuta = p_id_terapeuta);

    OPEN p_cursor FOR
        SELECT
            paciente,
            instrumento,
            dimension,
            fecha_respuesta,
            puntuacion,
            puntuacion_previa,
            delta_cambio,
            promedio_historico,
            CASE
                WHEN delta_cambio IS NULL THEN 'Línea Base'
                WHEN delta_cambio <= -3.00 THEN 'Mejoría Relevante'
                WHEN delta_cambio >= 3.00 THEN 'Alerta de Deterioro'
                ELSE 'Estable'
            END AS clasificacion_cambio
        FROM tmp_evolucion_longitudinal
        ORDER BY fecha_respuesta DESC, paciente ASC;

    p_mensaje := 'Evolución longitudinal calculada mediante tabla temporal y funciones de ventana.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en sp_reporte_evolucion_longitudinal: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_reporte_evolucion_longitudinal(IN p_id_terapeuta integer, INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_reporte_indicadores_anonimizados(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_reporte_indicadores_anonimizados(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.tmp_indicadores_anon;

    CREATE TEMP TABLE tmp_indicadores_anon (
        rango_etario text,
        modalidad character varying(50),
        pacientes_unicos integer,
        total_sesiones integer,
        pct_completadas numeric(5,2),
        promedio_escala numeric(5,2)
    ) ON COMMIT DROP;

    INSERT INTO tmp_indicadores_anon
    WITH pacientes_cohorte AS (
        SELECT
            id_paciente,
            CASE
                WHEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, fecha_nacimiento)) < 26 THEN '18-25 años'
                WHEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, fecha_nacimiento)) BETWEEN 26 AND 35 THEN '26-35 años'
                WHEN EXTRACT(YEAR FROM AGE(CURRENT_DATE, fecha_nacimiento)) BETWEEN 36 AND 50 THEN '36-50 años'
                ELSE '51+ años'
            END AS rango_etario
        FROM public.paciente
        WHERE id_estado_paciente = 1
    ),
    promedio_paciente AS (
        SELECT ai.id_paciente, AVG(ri.puntuacion_bruta) AS prom_bruto
        FROM public.aplicacion_instrumento ai
        JOIN public.resultado_instrumento ri ON ai.id_aplicacion = ri.id_aplicacion
        GROUP BY ai.id_paciente
    )
    SELECT
        pc.rango_etario,
        m.nombre AS modalidad,
        COUNT(DISTINCT pc.id_paciente) AS pacientes_unicos,
        COUNT(s.id_sesion) AS total_sesiones,
        CASE
            WHEN COUNT(s.id_sesion) = 0 THEN 0.00
            ELSE ROUND((COUNT(CASE WHEN s.id_estado_sesion = 2 THEN 1 END)::numeric * 100.0) / COUNT(s.id_sesion), 2)
        END AS pct_completadas,
        ROUND(COALESCE(AVG(pp.prom_bruto), 0), 2) AS promedio_escala
    FROM pacientes_cohorte pc
    JOIN public.asignacion_terapeuta_paciente a ON pc.id_paciente = a.id_paciente
    JOIN public.sesion s ON a.id_asignacion = s.id_asignacion
    JOIN public.modalidad_sesion m ON s.id_modalidad = m.id_modalidad
    LEFT JOIN promedio_paciente pp ON pc.id_paciente = pp.id_paciente
    GROUP BY pc.rango_etario, m.nombre;

    OPEN p_cursor FOR
        SELECT
            rango_etario,
            modalidad,
            pacientes_unicos,
            total_sesiones,
            pct_completadas,
            promedio_escala
        FROM tmp_indicadores_anon
        ORDER BY rango_etario ASC, modalidad ASC;

    p_mensaje := 'Indicadores anonimizados generados mediante tabla temporal (sin exposición de PII).';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en sp_reporte_indicadores_anonimizados: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_reporte_indicadores_anonimizados(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_reporte_ranking_terapeutas(refcursor); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_reporte_ranking_terapeutas(INOUT p_cursor refcursor, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    DROP TABLE IF EXISTS pg_temp.tmp_ranking_terapeutas;

    CREATE TEMP TABLE tmp_ranking_terapeutas (
        id_terapeuta integer,
        terapeuta text,
        cedula character varying(50),
        especialidades text,
        pacientes_activos integer,
        total_sesiones integer,
        completadas integer,
        canceladas integer,
        tasa_cumplimiento numeric(5,2)
    ) ON COMMIT DROP;

    INSERT INTO tmp_ranking_terapeutas
    SELECT
        dt.id_terapeuta,
        dt.nombre_terapeuta,
        dt.cedula_profesional,
        COALESCE(dt.especialidades, 'General'),
        COUNT(DISTINCT CASE WHEN a.id_estado_asignacion = 1 THEN a.id_paciente END) AS pacientes_activos,
        COUNT(s.id_sesion) AS total_sesiones,
        COUNT(CASE WHEN s.id_estado_sesion = 2 THEN 1 END) AS completadas,
        COUNT(CASE WHEN s.id_estado_sesion = 3 THEN 1 END) AS canceladas,
        CASE
            WHEN COUNT(s.id_sesion) = 0 THEN 0.00
            ELSE ROUND((COUNT(CASE WHEN s.id_estado_sesion = 2 THEN 1 END)::numeric * 100.0) / COUNT(s.id_sesion), 2)
        END AS tasa_cumplimiento
    FROM public.vw_directorio_terapeutas dt
    LEFT JOIN public.asignacion_terapeuta_paciente a ON dt.id_terapeuta = a.id_terapeuta
    LEFT JOIN public.sesion s ON a.id_asignacion = s.id_asignacion
    WHERE dt.estatus = 'Activo'
    GROUP BY dt.id_terapeuta, dt.nombre_terapeuta, dt.cedula_profesional, dt.especialidades;

    OPEN p_cursor FOR
        SELECT
            RANK() OVER (ORDER BY tasa_cumplimiento DESC, completadas DESC, pacientes_activos DESC) AS posicion,
            terapeuta,
            cedula,
            especialidades,
            pacientes_activos,
            total_sesiones,
            completadas,
            canceladas,
            tasa_cumplimiento
        FROM tmp_ranking_terapeutas
        ORDER BY posicion ASC, terapeuta ASC;

    p_mensaje := 'Ranking de terapeutas calculado mediante tabla temporal.';
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error en sp_reporte_ranking_terapeutas: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_reporte_ranking_terapeutas(INOUT p_cursor refcursor, OUT p_mensaje character varying) OWNER TO usuario;

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

--
-- Name: sp_validar_propiedad_asignacion(integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_validar_propiedad_asignacion(IN p_id_asignacion integer, IN p_id_terapeuta integer, OUT p_es_propietario boolean, OUT p_mensaje character varying)
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

--
-- Name: sp_validar_propiedad_objetivo(integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_validar_propiedad_objetivo(IN p_id_objetivo integer, IN p_id_terapeuta integer, OUT p_autorizado boolean, OUT p_id_plan integer, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT o.id_plan INTO p_id_plan
    FROM public.objetivo o
    JOIN public.plan_terapeutico pt ON o.id_plan = pt.id_plan
    JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
    WHERE o.id_objetivo = p_id_objetivo
      AND a.id_terapeuta = p_id_terapeuta
    LIMIT 1;

    IF p_id_plan IS NOT NULL THEN
        p_autorizado := TRUE;
        p_mensaje := 'Objetivo autorizado para el terapeuta.';
    ELSE
        p_autorizado := FALSE;
        p_mensaje := 'Acceso denegado: el objetivo no pertenece a tus pacientes asignados.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_autorizado := FALSE;
        p_id_plan := NULL;
        p_mensaje := 'Error al validar propiedad del objetivo: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_validar_propiedad_objetivo(IN p_id_objetivo integer, IN p_id_terapeuta integer, OUT p_autorizado boolean, OUT p_id_plan integer, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_validar_propiedad_paciente(integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_validar_propiedad_paciente(IN p_id_paciente integer, IN p_id_terapeuta integer, OUT p_autorizado boolean, OUT p_nombre_paciente character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    SELECT p.nombre || ' ' || p.apellido_paterno || ' ' || COALESCE(p.apellido_materno, '')
    INTO p_nombre_paciente
    FROM public.paciente p
    JOIN public.asignacion_terapeuta_paciente a ON p.id_paciente = a.id_paciente
    WHERE p.id_paciente = p_id_paciente
      AND a.id_terapeuta = p_id_terapeuta
      AND a.id_estado_asignacion = 1
    LIMIT 1;

    IF p_nombre_paciente IS NOT NULL THEN
        p_autorizado := TRUE;
        p_nombre_paciente := TRIM(p_nombre_paciente);
        p_mensaje := 'Paciente autorizado para el terapeuta.';
    ELSE
        p_autorizado := FALSE;
        p_nombre_paciente := NULL;
        p_mensaje := 'Acceso denegado: este paciente no está asignado al terapeuta autenticado.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_autorizado := FALSE;
        p_nombre_paciente := NULL;
        p_mensaje := 'Error al validar propiedad del paciente: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_validar_propiedad_paciente(IN p_id_paciente integer, IN p_id_terapeuta integer, OUT p_autorizado boolean, OUT p_nombre_paciente character varying, OUT p_mensaje character varying) OWNER TO usuario;

--
-- Name: sp_validar_propiedad_sesion(integer, integer); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_validar_propiedad_sesion(IN p_id_sesion integer, IN p_id_terapeuta integer, OUT p_tiene_acceso boolean, OUT p_mensaje character varying)
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

--
-- Name: sp_verificar_conexion(); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_verificar_conexion(OUT p_ok boolean, OUT p_mensaje character varying)
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

--
-- Name: sp_vincular_documento_aplicacion(integer, character varying); Type: PROCEDURE; Schema: public; Owner: usuario
--

CREATE PROCEDURE public.sp_vincular_documento_aplicacion(IN p_id_aplicacion integer, IN p_id_documento_mongo character varying, OUT p_mensaje character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_filas integer;
BEGIN
    UPDATE public.aplicacion_instrumento
    SET id_documento_mongo = p_id_documento_mongo,
        estado = COALESCE(estado, 'Completada'),
        fecha_respuesta = COALESCE(fecha_respuesta, CURRENT_TIMESTAMP)
    WHERE id_aplicacion = p_id_aplicacion;

    GET DIAGNOSTICS v_filas = ROW_COUNT;

    IF v_filas > 0 THEN
        p_mensaje := 'Documento MongoDB vinculado correctamente a la aplicación #' || p_id_aplicacion || '.';
    ELSE
        p_mensaje := 'No se encontró la aplicación de instrumento #' || p_id_aplicacion || '.';
    END IF;
EXCEPTION
    WHEN OTHERS THEN
        p_mensaje := 'Error al vincular documento en aplicacion_instrumento: ' || SQLERRM;
END;
$$;


ALTER PROCEDURE public.sp_vincular_documento_aplicacion(IN p_id_aplicacion integer, IN p_id_documento_mongo character varying, OUT p_mensaje character varying) OWNER TO usuario;

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
    fecha_creacion timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT chk_sesion_horario_valido CHECK ((hora_fin > hora_inicio))
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
1	1	1	1	Puntuación elevada detectada automáticamente (17.00 pts) en PHQ-9 (Depresión) — dimensión "Ánimo Depresivo Global" (aplicación #1). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
2	2	1	1	Puntuación elevada detectada automáticamente (16.00 pts) en GAD-7 (Ansiedad) — dimensión "Ansiedad Cognitiva" (aplicación #4). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
3	3	1	1	Puntuación elevada detectada automáticamente (19.00 pts) en PSS-10 (Estrés Percibido) — dimensión "Estrés Cotidiano" (aplicación #7). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
4	4	2	1	Puntuación elevada detectada automáticamente (15.00 pts) en GAD-7 (Ansiedad) — dimensión "Ansiedad Cognitiva" (aplicación #8). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
5	5	2	1	Puntuación elevada detectada automáticamente (18.00 pts) en PHQ-9 (Depresión) — dimensión "Ánimo Depresivo Global" (aplicación #11). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
6	29	11	1	Puntuación elevada detectada automáticamente (16.00 pts) en GAD-7 (Ansiedad) — dimensión "Ansiedad Cognitiva" (aplicación #13). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
7	33	11	1	Puntuación elevada detectada automáticamente (15.00 pts) en PHQ-9 (Depresión) — dimensión "Ánimo Depresivo Global" (aplicación #15). Requiere revisión terapéutica.	2026-11-26 20:06:07.179396	f
8	3	1	3	Sesión cancelada consecutiva; confirmar disponibilidad para reprogramación.	2026-11-26 20:06:07.179396	f
9	6	2	4	Objetivo de elaboración de duelo sin actualización en los últimos 21 días.	2026-11-26 20:06:07.179396	f
10	8	3	5	Revisar adherencia a desconexión digital en la próxima cita programada.	2026-11-26 20:06:07.179396	f
11	29	11	5	Validar respuesta positiva tras reducción de ansiedad en evaluación GAD-7.	2026-11-26 20:06:07.179396	f
\.


--
-- Data for Name: aplicacion_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.aplicacion_instrumento (id_aplicacion, id_instrumento, id_paciente, id_terapeuta, fecha_asignacion, fecha_respuesta, estado, id_documento_mongo) FROM stdin;
1	1	1	1	2026-08-05 09:00:00	2026-08-05 18:00:00	Completada	6b08fb8d288aca219b1d1c7b
2	1	1	1	2026-08-19 09:00:00	2026-08-19 19:00:00	Completada	6b08fb8d288aca219b1d1c7c
3	1	1	1	2026-09-02 09:00:00	2026-09-02 18:30:00	Completada	6b08fb8d288aca219b1d1c7d
4	2	2	1	2026-08-06 10:00:00	2026-08-06 17:00:00	Completada	6b08fb8d288aca219b1d1c7e
5	2	2	1	2026-08-20 10:00:00	2026-08-20 17:30:00	Completada	6b08fb8d288aca219b1d1c7f
6	3	3	1	2026-08-07 15:00:00	2026-08-07 20:00:00	Completada	6b08fb8d288aca219b1d1c80
7	3	3	1	2026-08-21 15:00:00	2026-08-21 20:15:00	Completada	6b08fb8d288aca219b1d1c81
8	2	4	2	2026-08-10 08:30:00	2026-08-10 14:00:00	Completada	6b08fb8d288aca219b1d1c82
9	2	4	2	2026-08-24 08:30:00	2026-08-24 14:30:00	Completada	6b08fb8d288aca219b1d1c83
10	1	5	2	2026-08-11 09:30:00	2026-08-11 16:00:00	Completada	6b08fb8e288aca219b1d1c84
11	1	5	2	2026-08-25 09:30:00	2026-08-25 16:10:00	Completada	6b08fb8e288aca219b1d1c85
12	4	7	3	2026-08-15 15:00:00	2026-08-15 19:00:00	Completada	6b08fb8e288aca219b1d1c86
13	2	29	11	2026-10-19 10:00:00	2026-10-19 18:00:00	Completada	6b08fb8e288aca219b1d1c87
14	2	29	11	2026-11-02 10:00:00	2026-11-02 18:30:00	Completada	6b08fb8e288aca219b1d1c88
15	1	33	11	2026-10-20 11:00:00	2026-10-20 19:00:00	Completada	6b08fb8e288aca219b1d1c89
16	1	33	11	2026-11-03 11:00:00	2026-11-03 19:15:00	Completada	6b08fb8e288aca219b1d1c8a
17	2	33	11	2026-11-26 21:51:54.216281	\N	Pendiente	\N
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
1	1	INSERT	Planes Terapéuticos	plan_terapeutico	1	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
2	1	INSERT	Planes Terapéuticos	plan_terapeutico	2	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
3	1	INSERT	Planes Terapéuticos	plan_terapeutico	3	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
4	1	INSERT	Planes Terapéuticos	plan_terapeutico	4	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
5	1	INSERT	Planes Terapéuticos	plan_terapeutico	5	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
6	1	INSERT	Planes Terapéuticos	plan_terapeutico	6	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
7	1	INSERT	Planes Terapéuticos	plan_terapeutico	7	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
8	1	INSERT	Planes Terapéuticos	plan_terapeutico	8	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
9	1	INSERT	Planes Terapéuticos	plan_terapeutico	9	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
10	1	INSERT	Planes Terapéuticos	plan_terapeutico	10	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
11	1	INSERT	Planes Terapéuticos	plan_terapeutico	11	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
12	1	INSERT	Planes Terapéuticos	plan_terapeutico	12	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
13	1	INSERT	Objetivos	objetivo	1	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
14	1	INSERT	Objetivos	objetivo	2	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
15	1	INSERT	Objetivos	objetivo	3	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
16	1	INSERT	Objetivos	objetivo	4	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
17	1	INSERT	Objetivos	objetivo	5	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
18	1	INSERT	Objetivos	objetivo	6	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
19	1	INSERT	Objetivos	objetivo	7	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
20	1	INSERT	Objetivos	objetivo	8	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
21	1	INSERT	Objetivos	objetivo	9	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
22	1	INSERT	Objetivos	objetivo	10	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
23	1	INSERT	Objetivos	objetivo	11	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
24	1	INSERT	Objetivos	objetivo	12	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
25	1	INSERT	Objetivos	objetivo	13	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
26	1	INSERT	Objetivos	objetivo	14	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
27	1	INSERT	Objetivos	objetivo	15	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
28	1	INSERT	Objetivos	objetivo	16	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
29	1	UPDATE	Objetivos	objetivo	1	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
30	1	UPDATE	Objetivos	objetivo	5	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
31	1	UPDATE	Planes Terapéuticos	plan_terapeutico	3	2026-11-26 20:06:07.179396	127.0.0.1	EXITO
\.


--
-- Data for Name: dimension_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.dimension_instrumento (id_dimension, id_instrumento, nombre_dimension) FROM stdin;
1	1	Ánimo Depresivo Global
2	1	Anhedonia y Energía
3	1	Alteración de Sueño
4	2	Ansiedad Cognitiva
5	2	Tensión Somática
6	3	Estrés Cotidiano
7	3	Sobrecarga Emocional
8	3	Afrontamiento Percibido
9	4	Vitalidad Diaria
10	4	Calidad de Descanso
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
1	1	25.00	2026-08-19 10:50:00	Se establecieron horarios base de descanso entre semana.	2
2	1	65.00	2026-09-02 10:50:00	Cumplimiento de 4 noches constantes; menor latencia de sueño.	2
3	1	100.00	2026-09-23 10:50:00	Meta consolidada durante 3 semanas seguidas.	2
4	2	30.00	2026-08-26 10:55:00	Primeros registros completos de pensamientos automáticos.	2
5	2	70.00	2026-09-16 10:55:00	Aplica reencuadre autónomo antes de reuniones críticas.	2
6	3	40.00	2026-08-20 11:50:00	Inició caminatas matutinas 2 días por semana.	2
7	3	80.00	2026-09-10 11:50:00	Mantiene 3 actividades semanales y reporta mejor energía.	2
8	4	35.00	2026-08-27 11:55:00	Practica respiración guiada antes de cenar.	2
9	5	50.00	2026-08-28 16:50:00	Uso de matriz de prioridades redujo entregas de último minuto.	2
10	5	100.00	2026-09-18 16:50:00	Logro completo del objetivo y cierre exitoso del plan 3.	2
11	6	45.00	2026-08-24 09:50:00	Primera conversación asertiva exitosa con su equipo.	3
12	6	85.00	2026-09-14 09:50:00	Mantiene límites saludables sin escalamiento emocional.	3
13	7	50.00	2026-08-25 10:50:00	Completa 5 días/semana de mindfulness guiado.	3
14	7	90.00	2026-09-15 10:50:00	Disminución notable en episodios de inquietud diurna.	3
15	8	40.00	2026-08-26 11:50:00	Apertura emocional constante en sesiones y bitácora.	3
16	9	55.00	2026-08-29 16:50:00	Reconoce autocrítica temprana y la reformula.	4
17	10	60.00	2026-08-30 17:50:00	Reduce uso de celular nocturno 4 noches por semana.	4
18	11	50.00	2026-09-01 18:50:00	Primera reunión familiar estructurada con acuerdos escritos.	4
19	12	75.00	2026-09-03 09:50:00	Pausas activas integradas en calendario laboral.	5
20	13	30.00	2026-10-25 15:00:00	Asistió a evento breve con manejo adecuado de respiración.	50
21	14	60.00	2026-11-01 15:00:00	Completó 4 registros semanales en bitácora emocional.	50
22	15	45.00	2026-10-26 15:10:00	Aplica respiración 4-7-8 en momentos de presión laboral.	50
23	15	75.00	2026-11-09 15:10:00	Reporta recuperación más rápida tras jornadas demandantes.	50
24	16	50.00	2026-11-09 15:15:00	Respondió evaluación inicial y seguimiento quincenal.	50
\.


--
-- Data for Name: instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.instrumento (id_instrumento, nombre, descripcion, estado, version, fecha_creacion) FROM stdin;
1	PHQ-9 (Depresión)	Cuestionario simulado de 9 ítems para seguimiento longitudinal de síntomas depresivos (0-27).	Activo	v1.0	2026-11-26 20:06:07.179396
2	GAD-7 (Ansiedad)	Escala simulada de 7 ítems para evaluación de ansiedad generalizada (0-21).	Activo	v1.0	2026-11-26 20:06:07.179396
3	PSS-10 (Estrés Percibido)	Escala simulada de percepción de estrés cotidiano y afrontamiento (0-40).	Activo	v1.0	2026-11-26 20:06:07.179396
4	WHO-5 (Bienestar)	Índice simulado de bienestar emocional positivo y vitalidad (0-25).	Activo	v1.0	2026-11-26 20:06:07.179396
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
2	1	1	Registro diario de pensamientos automáticos	Identificar detonantes de ansiedad y aplicar reencuadre cognitivo.	2026-08-05	2026-12-15
3	2	1	Rutina de activación conductual	Realizar 3 actividades placenteras o físicas estructuradas por semana.	2026-08-06	2026-11-20
4	2	1	Reducción de rumiación vespertina	Aplicar técnicas de respiración diafragmática y registro de cierre diario.	2026-08-13	2026-12-10
6	4	1	Comunicación asertiva en entorno laboral	Practicar peticiones claras y límites sin culpa en 2 situaciones semanales.	2026-08-10	2026-12-01
7	5	1	Práctica guiada de atención plena	Completar 10 minutos diarios de mindfulness durante 6 semanas.	2026-08-11	2026-11-25
8	6	1	Elaboración narrativa del duelo	Expresar emociones clave en bitácora semanal y revisar en sesión.	2026-08-12	2026-12-20
9	7	1	Fortalecimiento de autodiálogo compasivo	Sustituir autocrítica rígida por afirmaciones realistas basadas en evidencia.	2026-08-15	2026-12-05
10	8	1	Desconexión digital previa al descanso	Evitar pantallas 45 minutos antes de dormir.	2026-08-16	2026-11-18
11	9	1	Acuerdos claros de convivencia familiar	Establecer una reunión semanal estructurada de comunicación familiar.	2026-08-17	2026-12-12
12	10	1	Pausas de recuperación durante la jornada	Incorporar dos pausas de 10 minutos con estiramiento y respiración.	2026-08-18	2026-11-28
13	11	1	Exposición gradual a eventos sociales	Asistir a una actividad grupal breve por semana aplicando técnicas de calma.	2026-10-18	2026-12-20
14	11	1	Bitácora emocional de fin de día	Registrar intensidad emocional y estrategias utilizadas 4 veces por semana.	2026-10-18	2026-12-15
15	12	1	Control de estrés ante alta demanda	Aplicar técnica de respiración 4-7-8 en picos de tensión laboral.	2026-10-18	2026-12-18
16	12	1	Seguimiento quincenal con escalas psicométricas	Completar evaluaciones longitudinales PHQ-9 y GAD-7 en tiempo y forma.	2026-10-18	2026-12-22
1	1	2	Higiene del sueño consistente	Mantener horario regular de descanso al menos 5 noches por semana.	2026-08-05	2026-11-30
5	3	2	Planificación académica sin sobrecarga	Dividir entregables en bloques manejables con pausas activas.	2026-08-07	2026-11-15
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
1	gestionar_pacientes	Pacientes
2	gestionar_terapeutas	Terapeutas
3	gestionar_asignaciones	Asignaciones
4	ver_agenda_global	Sesiones
5	gestionar_sesiones_propias	Sesiones
6	ver_agenda_propia	Sesiones
7	gestionar_planes_objetivos	Planes Terapéuticos
8	aplicar_instrumentos	Instrumentos
9	responder_instrumentos	Instrumentos
10	gestionar_bitacora_propia	Bitácoras
11	ver_alertas_clinicas	Alertas
12	ver_auditoria_y_kpis	Auditoría
\.


--
-- Data for Name: plan_terapeutico; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.plan_terapeutico (id_plan, id_asignacion, id_estado_plan, fecha_inicio, fecha_fin, descripcion_general, fecha_creacion) FROM stdin;
1	1	1	2026-08-05	\N	Intervención cognitivo-conductual para manejo de ansiedad laboral y regulación del sueño.	2026-11-26 20:06:07.179396
2	2	1	2026-08-06	\N	Plan de activación conductual y reestructuración cognitiva ante episodios depresivos.	2026-11-26 20:06:07.179396
4	4	1	2026-08-10	\N	Terapia enfocada en habilidades de comunicación asertiva y límites saludables.	2026-11-26 20:06:07.179396
5	5	1	2026-08-11	\N	Abordaje de síntomas de ansiedad generalizada mediante exposición gradual y mindfulness.	2026-11-26 20:06:07.179396
6	6	1	2026-08-12	\N	Plan de duelo y adaptación emocional tras cambios familiares recientes.	2026-11-26 20:06:07.179396
7	7	1	2026-08-15	\N	Fortalecimiento de autoestima y regulación emocional en contexto universitario.	2026-11-26 20:06:07.179396
8	8	1	2026-08-16	\N	Estrategias de afrontamiento ante insomnio crónico y rumiación nocturna.	2026-11-26 20:06:07.179396
9	9	1	2026-08-17	\N	Intervención sistémica para mejora de dinámicas familiares y autocuidado.	2026-11-26 20:06:07.179396
10	10	1	2026-08-18	\N	Plan de manejo de estrés post-proyecto y recuperación de hábitos saludables.	2026-11-26 20:06:07.179396
11	29	1	2026-10-18	\N	Seguimiento terapéutico para regulación de ansiedad social y rutinas de bienestar.	2026-11-26 20:06:07.179396
12	30	1	2026-10-18	\N	Evaluación longitudinal y fortalecimiento de estrategias de manejo de estrés.	2026-11-26 20:06:07.179396
3	3	2	2026-08-07	2026-11-26	Acompañamiento para manejo del estrés académico y prevención de agotamiento.	2026-11-26 20:06:07.179396
\.


--
-- Data for Name: referencia_bitacora; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.referencia_bitacora (id_referencia, id_paciente, fecha_registro, id_documento_mongo) FROM stdin;
1	33	2026-11-26 21:39:58.817808	6b08fb8e288aca219b1d1c8b
2	33	2026-11-26 21:39:58.922937	6b08fb8e288aca219b1d1c8c
3	33	2026-11-26 21:39:59.025437	6b08fb8e288aca219b1d1c8d
4	33	2026-11-26 21:39:59.127453	6b08fb8f288aca219b1d1c8e
5	33	2026-11-26 21:39:59.228372	6b08fb8f288aca219b1d1c8f
6	33	2026-11-26 21:39:59.332369	6b08fb8f288aca219b1d1c90
7	33	2026-11-26 21:39:59.434716	6b08fb8f288aca219b1d1c91
8	33	2026-11-26 21:39:59.535677	6b08fb8f288aca219b1d1c92
9	29	2026-11-26 21:39:59.639002	6b08fb8f288aca219b1d1c93
10	29	2026-11-26 21:39:59.742485	6b08fb8f288aca219b1d1c94
11	29	2026-11-26 21:39:59.84261	6b08fb8f288aca219b1d1c95
12	29	2026-11-26 21:39:59.945314	6b08fb8f288aca219b1d1c96
13	29	2026-11-26 21:40:00.046723	6b08fb8f288aca219b1d1c97
14	1	2026-11-26 21:40:00.149164	6b08fb90288aca219b1d1c98
15	1	2026-11-26 21:40:00.25428	6b08fb90288aca219b1d1c99
16	2	2026-11-26 21:40:00.352905	6b08fb90288aca219b1d1c9a
17	3	2026-11-26 21:40:00.453408	6b08fb90288aca219b1d1c9b
18	5	2026-11-26 21:40:00.555011	6b08fb90288aca219b1d1c9c
\.


--
-- Data for Name: referencia_resumen; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.referencia_resumen (id_referencia, id_sesion, fecha_creacion, id_documento_mongo) FROM stdin;
1	39	2026-11-26 21:40:00.981103	6b08fb90288aca219b1d1c9d
2	38	2026-11-26 21:40:01.382743	6b08fb91288aca219b1d1ca0
3	37	2026-11-26 21:40:01.58659	6b08fb91288aca219b1d1ca3
4	36	2026-11-26 21:40:01.789245	6b08fb91288aca219b1d1ca5
5	35	2026-11-26 21:40:01.995493	6b08fb91288aca219b1d1ca7
6	34	2026-11-26 21:40:02.196952	6b08fb92288aca219b1d1ca9
7	33	2026-11-26 21:40:02.399233	6b08fb92288aca219b1d1cab
8	32	2026-11-26 21:40:02.600891	6b08fb92288aca219b1d1cad
9	31	2026-11-26 21:40:02.803807	6b08fb92288aca219b1d1caf
10	30	2026-11-26 21:40:03.003956	6b08fb92288aca219b1d1cb1
11	18	2026-11-26 21:40:03.209351	6b08fb93288aca219b1d1cb3
12	29	2026-11-26 21:40:03.409743	6b08fb93288aca219b1d1cb5
\.


--
-- Data for Name: resultado_instrumento; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.resultado_instrumento (id_resultado, id_aplicacion, id_dimension, puntuacion_bruta, fecha_calculo) FROM stdin;
1	1	1	17.00	2026-08-05 18:05:00
2	1	2	11.00	2026-08-05 18:05:00
3	2	1	13.00	2026-08-19 19:05:00
4	2	2	8.00	2026-08-19 19:05:00
5	3	1	8.00	2026-09-02 18:35:00
6	3	2	5.00	2026-09-02 18:35:00
7	4	4	16.00	2026-08-06 17:05:00
8	4	5	12.00	2026-08-06 17:05:00
9	5	4	11.00	2026-08-20 17:35:00
10	5	5	8.00	2026-08-20 17:35:00
11	6	6	14.00	2026-08-07 20:05:00
12	7	6	19.00	2026-08-21 20:20:00
13	8	4	15.00	2026-08-10 14:05:00
14	9	4	9.00	2026-08-24 14:35:00
15	10	1	12.00	2026-08-11 16:05:00
16	11	1	18.00	2026-08-25 16:15:00
17	12	9	14.00	2026-08-15 19:05:00
18	12	10	13.00	2026-08-15 19:05:00
19	13	4	16.00	2026-10-19 18:05:00
20	14	4	11.00	2026-11-02 18:35:00
21	15	1	15.00	2026-10-20 19:05:00
22	15	3	12.00	2026-10-20 19:05:00
23	16	1	10.00	2026-11-03 19:20:00
24	16	3	7.00	2026-11-03 19:20:00
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
1	1
1	2
1	3
1	4
1	11
1	12
2	5
2	7
2	8
2	11
3	6
3	9
3	10
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
1	1
1	2
2	2
2	5
3	1
3	3
4	4
4	6
5	1
5	7
6	5
6	9
7	2
7	8
8	1
9	9
10	10
11	1
11	2
\.


--
-- Data for Name: tipo_alerta; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.tipo_alerta (id_tipo_alerta, nombre, descripcion) FROM stdin;
1	Riesgo Clínico Elevado	Puntuación psicométrica por encima del umbral moderado-alto (>= 15 pts).
2	Incremento Sintomático	Aumento significativo respecto a la evaluación longitudinal previa.
3	Inasistencia Reiterada	Cancelaciones consecutivas que comprometen la adherencia terapéutica.
4	Objetivo Estancado	Objetivo terapéutico sin progreso registrado en más de 3 semanas.
5	Seguimiento Prioritario	Requiere revisión clínica en la próxima sesión programada.
\.


--
-- Data for Name: usuario; Type: TABLE DATA; Schema: public; Owner: usuario
--

COPY public.usuario (id_usuario, id_rol, id_estado_usuario, correo, password_hash, fecha_creacion, ultimo_acceso) FROM stdin;
2	2	1	terapeuta1@clinica.com	scrypt:32768:8:1$ezLfDsNtl3CFnK8C$14e046aafffceb28fa160eb28abdd79f67f0acdfeb57b5f41a8d7003cf059ef00878cf726cd2d8339e21e757433f498b84288b36a8ef3ebed71b5092d8f3cec3	2026-10-17 19:55:18.010379	\N
3	2	1	terapeuta2@clinica.com	scrypt:32768:8:1$PxcVSXxGX5PCnkVp$d63a437a5d208e81c5527cba85513b40b28fdd00c42457b4e34918b715ee468abfc991f671d16bf7be825c37ad57016246ea3ca87ea0101a1161fc3cbfacdca0	2026-10-17 19:55:18.010379	\N
4	2	1	terapeuta3@clinica.com	scrypt:32768:8:1$8dKXygXAi4MUdzOO$031ec4a37527549d248e5cd585de77dc46b7def51b3eb9cfea1c7509f35ea392401907a0a37df6bd1f7046a1f8f74db601ec21e20d8a9843135d7b08a75b0d86	2026-10-17 19:55:18.010379	\N
5	2	1	terapeuta4@clinica.com	scrypt:32768:8:1$mlJbAqU6gqhW6eJ6$ee07c8520b311b0c717a1f90883eb6fc61acb0ecfe6fa8930a9680bfa1ddf324c5b47a00afd59be41bcb31da5af7e186273971cbc8489687aabda6ac7a92c03a	2026-10-17 19:55:18.010379	\N
6	2	1	terapeuta5@clinica.com	scrypt:32768:8:1$czCuz1zobP64ImDe$fab873258219fcda8dca682723ab1991de3b95f92b1deedcbc8c8ea3dab52edfc0d113630fa943ae3bfbc3322f5cb5385e4a767b8fe2609b9a83aa729590369b	2026-10-17 19:55:18.010379	\N
7	2	1	terapeuta6@clinica.com	scrypt:32768:8:1$RA82ln7CbwPSdAOf$62f957172a04d399fcff2b42e9f1a41f88949afd58ec21737cf2efa843b3bb7c9a1bce25c0fe9906ac96cc040026bada813516838e17dcad9076cd30147f672e	2026-10-17 19:55:18.010379	\N
8	2	1	terapeuta7@clinica.com	scrypt:32768:8:1$WmbK7Uc1heKGxpFM$53e3469d89c090f04d3a860ca66ad8d002b238d60db101f65d48955fe980d339908932e94b69e0be87fa4f985c7957057f4443e94bebd082f3038ca73bd372bf	2026-10-17 19:55:18.010379	\N
9	2	1	terapeuta8@clinica.com	scrypt:32768:8:1$gJWpV58lXoKEbjjM$c94470b37ba26a99e6e3bd7dff774a9c8653f680c55abdbf4feae2ee068cd372c93e79f08ecf8eebecbb84d3e62ef123f7cb26f99d2986bb918566b06da20d4d	2026-10-17 19:55:18.010379	\N
10	2	1	terapeuta9@clinica.com	scrypt:32768:8:1$ucq6qCSmTWK7fGlL$3ac75c76abf4bb90a21c64047e67af3d9b0ed3f6562dca06abf6a2e01918ae33d1c0dce486f25658aa94a46dd8938ab62e4cda34d2ade54a8ebe671cde947898	2026-10-17 19:55:18.010379	\N
11	2	1	terapeuta10@clinica.com	scrypt:32768:8:1$nXziezbpLltp91hT$038946bd69f533632f893d02036d108565d404967897d75436196834ad6a6107f15214a5c1a0cd104bb277e8adaf6e1ede2280ec30b6f928e1e4d4f8ede5c207	2026-10-17 19:55:18.010379	\N
12	3	1	paciente1@correo.com	scrypt:32768:8:1$N32A2TxZzGOMBZlT$361faed09e0c6810cfd7fd231d3e97aca65c6800d337b6544d887bb617809a96355cc34884dcbb72a5f3416ca65c08a4bda4d2d65f01daf9bd688893e06dc34c	2026-10-17 19:55:18.010379	\N
13	3	1	paciente2@correo.com	scrypt:32768:8:1$gPdkkEYKBCGB1F2v$23764701ea1403c171030b81d49a078e7ee146c6f8964b743a21db74ba437f0b2781b58b8807cf639c09a348d9c203f76ae9975defb546daaebea17af9ef9da9	2026-10-17 19:55:18.010379	\N
1	1	1	admin@clinica.com	scrypt:32768:8:1$nJed2mU8SQdyNIlR$3359d818734171072be58ed9f13662d9b1533ca3b7482108386750bb4efc0c0df7e1f46e05c2a929be02e5aa83cb5de1d96d4f33411c1c94ad4b9fb2632957ad	2026-10-17 19:55:18.010379	2026-11-26 21:51:51.720858
14	3	1	paciente3@correo.com	scrypt:32768:8:1$a2TONRnNhItZaVat$59b23c4ebec173702da48b5a16df6f0db0cecafe4481b2307befbe88a6041d2c4f4d513b9aa4b565ae7d2367c9a34244f63d541ee1d0a0f1c55e0348f4e149cf	2026-10-17 19:55:18.010379	\N
15	3	1	paciente4@correo.com	scrypt:32768:8:1$Ga5MpM7IKmywdJfy$74183073a89781c15261c6c704e7e20ea948b8e8ef88c587f1a8ea65742c924a9e17af013011fc463e7bc3e80cb38507dea71c1689dc2ff771af8bd140990ff6	2026-10-17 19:55:18.010379	\N
16	3	1	paciente5@correo.com	scrypt:32768:8:1$jAvE001JM0bGF2XL$1e709a2e15506e666c4c48f4594a5e29664402c389aeee6e7f6744898deb64ef0241a1b6499598efdd879cca5bc6463fb984b97523a7324e6a7f6dbfc25d9e1c	2026-10-17 19:55:18.010379	\N
17	3	1	paciente6@correo.com	scrypt:32768:8:1$D9GNhHaB34SiAQ8g$bd41b56c35197d4aa7e80991b36e24fe7db48e5ee22b2454c75479f70c511d506e821fb7e0ba1aa0922b80cb6f95e4c80fa7c4c236ce865338c432e233a2cc76	2026-10-17 19:55:18.010379	\N
18	3	1	paciente7@correo.com	scrypt:32768:8:1$zl6cMPcO5QN2dBVC$57aff57a69190668a163aff3dccca1bd55f662a70f27d9e9fb368808b8fda276d67c81ea74f45dbcf8fbbc30ff200b7c4f5f1b3810e53f988e527d85de37d8c6	2026-10-17 19:55:18.010379	\N
19	3	1	paciente8@correo.com	scrypt:32768:8:1$QSOR7Xup9HMkHASl$ef80f4d0fc5b840e803bb1777e0b2da13e468950ad01f32c930b2ae9af8a9fe712b074000b9cc12d140e56e42fe57968f34e1b33316a823f5250d596168877ac	2026-10-17 19:55:18.010379	\N
20	3	1	paciente9@correo.com	scrypt:32768:8:1$RtRZpy9c9josm89m$19824c49911c99be47d494fc08b73a22be5288aa6e644562109c3de9736d541dec59361748ebc635f035172924a7f4dcd42b61e247bf7fc57bdcc8099daabf5e	2026-10-17 19:55:18.010379	\N
21	3	1	paciente10@correo.com	scrypt:32768:8:1$YoM8uRkzFHRk7xf0$b29059a68dc378557b651e9b07fa43daa47cbf377dfe62d1bba03c59590c3fb6718d8fe716a4571c2baeb66ebefcf5898add37bf54ea02c9c95072c591bad11f	2026-10-17 19:55:18.010379	\N
22	3	1	paciente11@correo.com	scrypt:32768:8:1$CFUrZf6pNpCAM73d$6bb103468a829a9ad8b322581488c194ffbd7d82e2557e54c9068514921f64843993a20a8ae9f0b6d0b450b027b142daa62ca6e1285d7767c7841ed98418ee33	2026-10-17 19:55:18.010379	\N
23	3	1	paciente12@correo.com	scrypt:32768:8:1$9vBjFm1LqoC7e9NU$fd0be0741abffd2db99d62b2561c7333ba99391000192d11bab51e7de779b1b86a69a4180eefdc9403a99d18788d566c02b5d2767e2fa53cdbf790efab199b8f	2026-10-17 19:55:18.010379	\N
24	3	1	paciente13@correo.com	scrypt:32768:8:1$G6MIQVX1r8bsiGa7$3fcea1a70ade61f823b235fb86a03b7810186c6fe24bc882cf3286a157c99774c3df61db68f4f2a9d714fed4f66e7baf0a3bc75c2455b2c2a937535e19d2e0e6	2026-10-17 19:55:18.010379	\N
25	3	1	paciente14@correo.com	scrypt:32768:8:1$2oVKTNdTLzJHPCra$19dfe286c24ffd6c6b16d0d3a42480d2cd606741fe300d0753a7df81fc683bee3ac9eee485c9cfc180f43c0999b9887468676ff712ad925baf7d4a56c7b118cb	2026-10-17 19:55:18.010379	\N
26	3	1	paciente15@correo.com	scrypt:32768:8:1$i8oIiUoyRrCHazTo$0d9075fe70fa8ec3e14af9335f5c3ac4c7c24ddc245cc60ff9fd6a2651ad903389dc14f1295b18e3b308204a9240551cc96ee13aa1c4aec721463456c1a057f6	2026-10-17 19:55:18.010379	\N
27	3	1	paciente16@correo.com	scrypt:32768:8:1$PildSu37aZXH8jBP$a13c8ea4643a70cf61a3a7c03e9e8a3365e67ba60ec5d70c810172d89688a55cb02c0bcb959e652901864aaced0b8dd707c292b0d6cd91b988f8b7c44333b862	2026-10-17 19:55:18.010379	\N
28	3	1	paciente17@correo.com	scrypt:32768:8:1$MPiv0ZHMy4NbV5sR$673b89da4b34ef0313e79dec1a9145f85cee29f8f8f26fd5efb420de3ca4ede0242708408aed14b7a81b13c7f5d951ba30532c571d3904b252aad357599bdc79	2026-10-17 19:55:18.010379	\N
29	3	1	paciente18@correo.com	scrypt:32768:8:1$iNBC8Fiaze9iXhra$309e2c43809eb19615f4a4fca001d6a9e279a3d0b464728f4240fc0528661ada5852939443948d5bc3082f3256befb6145ab07ca3a0dc9c0df3aeb0d63c10624	2026-10-17 19:55:18.010379	\N
30	3	1	paciente19@correo.com	scrypt:32768:8:1$zeCrzi10nr251bUj$1f9e08e0bfa93a716fb59d80244481014f75ea9493f0756683f0a679111645fd0c4e1c85b15d277d58c9b3606ec9e7c4093d111cb4f8c408d73ac787df2c9f28	2026-10-17 19:55:18.010379	\N
31	3	1	paciente20@correo.com	scrypt:32768:8:1$cdjSVSFblTQb8Sf7$104c2d674b04ce5756457db121f3329f8904a237eaa8c29b2c17e5cd7283926791bc0f3d9cac3128e59bdf3988c94eba46800ec6e22f303e7239a061ca666cd9	2026-10-17 19:55:18.010379	\N
32	3	1	paciente21@correo.com	scrypt:32768:8:1$XFX1NNENJlrSu4k6$1087ee6c6f27eabee0f99a5c4faa897e802a43f87dacf6ba19672b2b8cab26f27be5cf39702abc1e0c7f6a612c08c4c993b51e1c2c3197b8c2d0d522b8c8cb54	2026-10-17 19:55:18.010379	\N
33	3	1	paciente22@correo.com	scrypt:32768:8:1$e6fgQO8yJdoNdafT$83de83dde97e482854306a4845618745bf9213daaed992c0e984024425cdbe539e12a6d9fdd482c10372aa12a5f831746063a89abd75a9c035ea2c6991adf997	2026-10-17 19:55:18.010379	\N
34	3	1	paciente23@correo.com	scrypt:32768:8:1$7g6E3yqTF12Hc4QA$ee8cfc2abe5cda9dca957ba9904e6feffb01d7d97f3033c6c1714175ffddf696d052079751a7ea67bdd665297b13e1789102ecaf8d9c5ec074f0b15dc0fcae90	2026-10-17 19:55:18.010379	\N
35	3	1	paciente24@correo.com	scrypt:32768:8:1$4ofdOSpIeJWPjis6$845640873a4b0d44376a742502eaeef59b54e826d253549093d4b0e457c5254420ed37763aef72e8fc441585f21fdd37a7394cc654f0fe60f4aeb29e79d0a1c5	2026-10-17 19:55:18.010379	\N
36	3	1	paciente25@correo.com	scrypt:32768:8:1$IvN23567ploheXa3$8b9b35977ad1bb81edf40a396545c97bdec9f254a145cf9121df267026aca593bd119fa264b05c60efb003c72cf62064bbdb0a9745675021ddf214775532a067	2026-10-17 19:55:18.010379	\N
37	3	1	paciente26@correo.com	scrypt:32768:8:1$xDQhzPHbw0KaU20X$5532adf7eca3e871f0708a79e9529fa9d035196fced626777a84139c13bb893503053cb0630beea6dfb2dbca63e8972f93bf86e8fe9a111c7ab7c603f8534bbf	2026-10-17 19:55:18.010379	\N
38	3	1	paciente27@correo.com	scrypt:32768:8:1$tKKaJf4ocW236O2y$d8ab79bd4af00df464c77f55c11fcdea0273d996c638bc6c52b4546da608246455108782212c87db85342ea8af34ce0e3375e738e881d72c616c59df33410e4b	2026-10-17 19:55:18.010379	\N
39	3	1	paciente28@correo.com	scrypt:32768:8:1$KE9F116dqMrYKK3n$52cc2d5553dba85c1123e23eaf6a036769bf4e8df4b270ff34b068e91f8e888a049b1f805e4b25e8c2c4aa28f9f7316ab06ac7573bfe763aa102990383b64ecb	2026-10-17 19:55:18.010379	\N
40	3	1	paciente29@correo.com	scrypt:32768:8:1$pSJv6VRoih9V0p6X$3751f6f5a6a392ddbc840017041e1d05024cad9fe8227a9b5105e223b6b9efffc623da7b2a28efaddabca9edd850d4fae007e657e284bbe9fbe77ef93320e3bb	2026-10-17 19:55:18.010379	\N
41	3	1	paciente30@correo.com	scrypt:32768:8:1$0kuc3WDmleU9SRxU$2a78d0ca09e41e6a5328cb63f0a415b95709fef43a91fe56b231c74eee651bb262018d72eae9eac7a52c1b11344bdf4001d8db90dd09a6ba73d893df38504625	2026-10-17 19:55:18.010379	\N
42	3	2	paola.taha@gmail.com	scrypt:32768:8:1$PjqhQKDOlJ5V0ieN$1bdff77a6fb39e641bb7476e306d3b256d82634b7954e5b77747adf017eafb68ac1a05da5b69e23ff73cbbf76a449b0ffff6f392697b1107511b8df4cb3cedde	2026-10-18 02:20:41.891364	\N
45	3	1	paola.tah@gmail.com	scrypt:32768:8:1$i6pUoBBoKoS6ekJE$05079ef984741ee5b69013d4f9e5a44a284f7cf631f156abe80ccbd09df89a8ca979bdbfbcb5a3718d3102664def3f3d88370b24eed24aef93b66b9086ee4303	2026-10-18 02:35:54.020426	\N
46	2	1	zeus.fernando@gmail.com	scrypt:32768:8:1$gfNSUipAUjChgcXi$a87a0c0292ce19de18c17048c829fa8e07744e6340d5aeb7e47fd8b12d429b69f1a56241279e9ac292fc373cf75ca2363800f67e9db671e9e673bb9213ebed92	2026-10-18 03:05:44.988707	\N
47	3	1	ce_aguilar@hotmail.com	scrypt:32768:8:1$z6clz8BuPzfmuhKd$c3d28d85331378f3664cf59bf0e21b61b990dc6e4d71bb8e1cbb8e77ed825b2bfdc984c8323b6fbb029a2d39e158bd991747b588bfb8ce5ec0d96f9b39344ac3	2026-10-18 03:08:25.882202	\N
48	3	2	eduardo.aguilar@directlink.net.mx	scrypt:32768:8:1$28vHEWzqcAyOcrBt$cc8a44db8f8270c48167f57e9e9cf2a81927647e8a0f3402ef5dcbf14788674f08889faffdc6dbafacc9b7b10e2e41f9413959b736e5a377be559932e2d17220	2026-10-18 03:37:49.230778	\N
52	3	2	email@gmail.com	scrypt:32768:8:1$F3qnbKPJ1rW0UlEH$947e6f947d9078a28a173628524762a19121466f6d1497c9743e3213b483b5869100e487d55f26a6d222df6b174a2d3236f7829ffd61b6eb96902e9c33981770	2026-10-22 14:41:28.265484	\N
50	2	1	paola.terapeuta@clinica.com	scrypt:32768:8:1$CGMEvwdI30D4WPyb$abdd0cc43bcfbdcf9c63236f3a269b7fdf584aa10fff8f7a075e9d0ee04deef62752d102c6a8c0aa504d5ced279c3ef3e2cfb6c1661ad6b4ed1bbe9d8aae93e6	2026-10-18 22:07:13.917424	2026-11-26 21:51:52.889605
51	3	1	carlos.paciente@clinica.com	scrypt:32768:8:1$pFvaN6CSan2V1Eg6$58c588d643ae437b3ea2be96c7740930127e9f4b87e5ae46f3b62349ea7abb2216cf86d5edbd6bf2e8f2a415d6ff84fe3d130c2ad2f63416e5f613f16b069766	2026-10-18 23:06:25.68	2026-11-26 21:51:54.423414
\.


--
-- Name: alerta_id_alerta_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.alerta_id_alerta_seq', 11, true);


--
-- Name: aplicacion_instrumento_id_aplicacion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.aplicacion_instrumento_id_aplicacion_seq', 17, true);


--
-- Name: asignacion_terapeuta_paciente_id_asignacion_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.asignacion_terapeuta_paciente_id_asignacion_seq', 30, true);


--
-- Name: auditoria_id_auditoria_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.auditoria_id_auditoria_seq', 31, true);


--
-- Name: dimension_instrumento_id_dimension_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.dimension_instrumento_id_dimension_seq', 10, true);


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

SELECT pg_catalog.setval('public.historial_objetivo_id_historial_seq', 24, true);


--
-- Name: instrumento_id_instrumento_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.instrumento_id_instrumento_seq', 4, true);


--
-- Name: modalidad_sesion_id_modalidad_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.modalidad_sesion_id_modalidad_seq', 2, true);


--
-- Name: objetivo_id_objetivo_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.objetivo_id_objetivo_seq', 16, true);


--
-- Name: paciente_id_paciente_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.paciente_id_paciente_seq', 35, true);


--
-- Name: permiso_id_permiso_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.permiso_id_permiso_seq', 12, true);


--
-- Name: plan_terapeutico_id_plan_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.plan_terapeutico_id_plan_seq', 12, true);


--
-- Name: referencia_bitacora_id_referencia_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.referencia_bitacora_id_referencia_seq', 19, true);


--
-- Name: referencia_resumen_id_referencia_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.referencia_resumen_id_referencia_seq', 12, true);


--
-- Name: resultado_instrumento_id_resultado_seq; Type: SEQUENCE SET; Schema: public; Owner: usuario
--

SELECT pg_catalog.setval('public.resultado_instrumento_id_resultado_seq', 24, true);


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

SELECT pg_catalog.setval('public.tipo_alerta_id_tipo_alerta_seq', 6, true);


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
-- Name: idx_alerta_terapeuta_atendida; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_alerta_terapeuta_atendida ON public.alerta USING btree (id_terapeuta, atendida);


--
-- Name: idx_aplicacion_paciente_fecha; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_aplicacion_paciente_fecha ON public.aplicacion_instrumento USING btree (id_paciente, fecha_respuesta DESC);


--
-- Name: idx_asignacion_paciente_estado; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_asignacion_paciente_estado ON public.asignacion_terapeuta_paciente USING btree (id_paciente, id_estado_asignacion);


--
-- Name: idx_asignacion_terapeuta_estado; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_asignacion_terapeuta_estado ON public.asignacion_terapeuta_paciente USING btree (id_terapeuta, id_estado_asignacion);


--
-- Name: idx_auditoria_fecha_desc; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_auditoria_fecha_desc ON public.auditoria USING btree (fecha_hora DESC);


--
-- Name: idx_historial_objetivo_fecha; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_historial_objetivo_fecha ON public.historial_objetivo USING btree (id_objetivo, fecha_registro DESC);


--
-- Name: idx_resultado_aplicacion_dimension; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_resultado_aplicacion_dimension ON public.resultado_instrumento USING btree (id_aplicacion, id_dimension);


--
-- Name: idx_sesion_asignacion; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_sesion_asignacion ON public.sesion USING btree (id_asignacion);


--
-- Name: idx_sesion_fecha_estado; Type: INDEX; Schema: public; Owner: usuario
--

CREATE INDEX idx_sesion_fecha_estado ON public.sesion USING btree (fecha DESC, id_estado_sesion);


--
-- Name: resultado_instrumento trg_alerta_riesgo_instrumento; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_alerta_riesgo_instrumento AFTER INSERT ON public.resultado_instrumento FOR EACH ROW EXECUTE FUNCTION public.fn_alerta_riesgo_instrumento();


--
-- Name: asignacion_terapeuta_paciente trg_auditoria_asignacion; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_asignacion AFTER INSERT OR UPDATE ON public.asignacion_terapeuta_paciente FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Asignaciones', 'id_asignacion');


--
-- Name: objetivo trg_auditoria_objetivo; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_objetivo AFTER INSERT OR UPDATE ON public.objetivo FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Objetivos', 'id_objetivo');


--
-- Name: paciente trg_auditoria_paciente; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_paciente AFTER INSERT OR UPDATE ON public.paciente FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Pacientes', 'id_paciente');


--
-- Name: plan_terapeutico trg_auditoria_plan_terapeutico; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_plan_terapeutico AFTER INSERT OR UPDATE ON public.plan_terapeutico FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Planes Terapéuticos', 'id_plan');


--
-- Name: sesion trg_auditoria_sesion; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_sesion AFTER INSERT OR UPDATE ON public.sesion FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Sesiones', 'id_sesion');


--
-- Name: terapeuta trg_auditoria_terapeuta; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_auditoria_terapeuta AFTER INSERT OR UPDATE ON public.terapeuta FOR EACH ROW EXECUTE FUNCTION public.fn_auditoria_clinica('Terapeutas', 'id_terapeuta');


--
-- Name: historial_objetivo trg_progreso_reactivo_objetivo; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_progreso_reactivo_objetivo AFTER INSERT ON public.historial_objetivo FOR EACH ROW EXECUTE FUNCTION public.fn_progreso_reactivo_objetivo();


--
-- Name: sesion trg_validar_sesion_integridad; Type: TRIGGER; Schema: public; Owner: usuario
--

CREATE TRIGGER trg_validar_sesion_integridad BEFORE INSERT OR UPDATE ON public.sesion FOR EACH ROW EXECUTE FUNCTION public.fn_validar_sesion_integridad();


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

\unrestrict b0RyQd5Rs0NqKZJdXX8PgD8brGZijFtT3qV890peIAI8IlYODHWMoI64Ft7T35v

