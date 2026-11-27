-- ============================================================================
-- Fase 5 (04): Stored Procedures de Módulos Clínicos Completos
--   - Validación de propiedad Terapeuta <-> Paciente
--   - Planes Terapéuticos y Objetivos (CRUD + historial)
--   - Cuestionarios Psicométricos Simulados (asignación y registro de resultados)
--   - Flujo Completo de Consulta, Reprogramación y Nota SOAP
-- Sistema de Gestión Clínica (Equipo 01) — Regla R1 (Acceso exclusivo vía SP)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Validar propiedad de un paciente para un terapeuta autenticado
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_validar_propiedad_paciente(
    IN p_id_paciente integer,
    IN p_id_terapeuta integer,
    OUT p_autorizado boolean,
    OUT p_nombre_paciente character varying,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 2. Consultar planes terapéuticos (filtrado por terapeuta o por paciente)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_consultar_planes_terapeuticos(
    IN p_id_terapeuta integer,
    IN p_id_paciente integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 3. Crear un nuevo plan terapéutico (activa trigger de auditoría)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_crear_plan_terapeutico(
    IN p_id_asignacion integer,
    IN p_fecha_inicio date,
    IN p_descripcion text,
    OUT p_id_plan integer,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 4. Obtener detalle de un plan terapéutico validando propiedad
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_obtener_plan_detalle(
    IN p_id_plan integer,
    IN p_id_terapeuta integer,
    IN p_id_paciente integer,
    INOUT p_cursor refcursor,
    OUT p_autorizado boolean,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 5. Consultar objetivos de un plan con su último porcentaje de avance
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_consultar_objetivos_de_plan(
    IN p_id_plan integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 6. Crear objetivo dentro de un plan terapéutico (reactiva plan si estaba cerrado)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_crear_objetivo(
    IN p_id_plan integer,
    IN p_nombre character varying,
    IN p_descripcion text,
    IN p_fecha_inicio date,
    IN p_fecha_meta date,
    OUT p_id_objetivo integer,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 7. Validar propiedad de un objetivo para el terapeuta antes de registrar avance
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_validar_propiedad_objetivo(
    IN p_id_objetivo integer,
    IN p_id_terapeuta integer,
    OUT p_autorizado boolean,
    OUT p_id_plan integer,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 8. Listar catálogo de instrumentos psicométricos activos
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_listar_instrumentos_activos(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 9. Consultar aplicaciones de instrumentos (por terapeuta o por paciente)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_consultar_aplicaciones_instrumentos(
    IN p_id_terapeuta integer,
    IN p_id_paciente integer,
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

-- ----------------------------------------------------------------------------
-- 10. Asignar un cuestionario psicométrico a un paciente del terapeuta
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_asignar_instrumento(
    IN p_id_instrumento integer,
    IN p_id_paciente integer,
    IN p_id_terapeuta integer,
    OUT p_id_aplicacion integer,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 11. Obtener detalle de una aplicación validando propiedad (Terapeuta o Paciente)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_obtener_aplicacion_detalle(
    IN p_id_aplicacion integer,
    IN p_id_terapeuta integer,
    IN p_id_paciente integer,
    INOUT p_cursor refcursor,
    OUT p_autorizado boolean,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 12. Registrar resultado numérico por dimensión (dispara trg_alerta_riesgo_instrumento si >= 15)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_registrar_resultado_dimension(
    IN p_id_aplicacion integer,
    IN p_id_dimension integer,
    IN p_puntuacion numeric,
    OUT p_id_resultado integer,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 13. Obtener detalle de una sesión clínica (para Consulta/SOAP o Reprogramar)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_obtener_detalle_sesion(
    IN p_id_sesion integer,
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_autorizado boolean,
    OUT p_mensaje character varying
)
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
