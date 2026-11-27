-- ============================================================================
-- Fase 4 (04): Stored Procedures de Coordinación PostgreSQL <-> MongoDB
-- Enlazan los documentos de MongoDB (ObjectId de 24 caracteres hex) con las
-- tablas relacionales aplicacion_instrumento, referencia_bitacora y
-- referencia_resumen manteniendo acceso 100% exclusivo vía SP (Regla R1).
-- Sistema de Gestión Clínica (Equipo 01)
-- ============================================================================

-- 1. Vincular id_documento_mongo a una aplicación de instrumento en PostgreSQL
CREATE OR REPLACE PROCEDURE public.sp_vincular_documento_aplicacion(
    IN p_id_aplicacion integer,
    IN p_id_documento_mongo character varying,
    OUT p_mensaje character varying
)
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

-- 2. Registrar referencia de bitácora emocional (PostgreSQL <-> MongoDB)
CREATE OR REPLACE PROCEDURE public.sp_registrar_referencia_bitacora(
    IN p_id_paciente integer,
    IN p_id_documento_mongo character varying,
    OUT p_id_referencia integer,
    OUT p_mensaje character varying
)
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

-- 3. Listar referencias de bitácoras emocionales por paciente
CREATE OR REPLACE PROCEDURE public.sp_listar_referencias_bitacora(
    IN p_id_paciente integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- 4. Registrar o actualizar referencia de resumen SOAP de sesión
CREATE OR REPLACE PROCEDURE public.sp_registrar_referencia_resumen(
    IN p_id_sesion integer,
    IN p_id_documento_mongo character varying,
    OUT p_id_referencia integer,
    OUT p_mensaje character varying
)
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

-- 5. Listar referencias de resúmenes SOAP (global o filtrado por terapeuta)
CREATE OR REPLACE PROCEDURE public.sp_listar_referencias_resumen(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- 6. Listar aplicaciones de instrumentos para sincronización semilla con MongoDB
CREATE OR REPLACE PROCEDURE public.sp_listar_aplicaciones_seed_mongo(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- 7. Listar resultados numéricos de una aplicación específica
CREATE OR REPLACE PROCEDURE public.sp_listar_resultados_de_aplicacion(
    IN p_id_aplicacion integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- 8. Listar sesiones completadas para sincronización inicial de resúmenes SOAP
CREATE OR REPLACE PROCEDURE public.sp_listar_sesiones_completadas_seed_mongo(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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
