-- ============================================================================
-- Fase 3 (04): Stored Procedures de integración de Vistas (vw_*) y
-- 4 Stored Procedures de Reportes/Rankings/Agregaciones con Tablas Temporales
-- (CREATE TEMP TABLE ... ON COMMIT DROP).
-- Sistema de Gestión Clínica (Equipo 01)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Contexto de auditoría por transacción (usuario autenticado + IP cliente)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE public.sp_establecer_contexto_auditoria(
    IN p_id_usuario integer,
    IN p_ip character varying,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 2. Integración de vistas vw_* vía Stored Procedures (acceso exclusivo SP)
-- ----------------------------------------------------------------------------

-- Vista: vw_directorio_pacientes
CREATE OR REPLACE PROCEDURE public.sp_consultar_directorio_pacientes(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- Vista: vw_directorio_terapeutas
CREATE OR REPLACE PROCEDURE public.sp_consultar_directorio_terapeutas(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- Vista: vw_reporte_auditoria (Solo Admin)
CREATE OR REPLACE PROCEDURE public.sp_consultar_auditoria(
    IN p_limite integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- Vista: vw_alertas_activas (Admin: todas | Terapeuta: solo las de sus pacientes)
CREATE OR REPLACE PROCEDURE public.sp_consultar_alertas_activas(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- Atender una alerta clínica (validando propiedad si p_id_terapeuta IS NOT NULL)
CREATE OR REPLACE PROCEDURE public.sp_atender_alerta(
    IN p_id_alerta integer,
    IN p_id_terapeuta integer,
    OUT p_atendida boolean,
    OUT p_mensaje character varying
)
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

-- Vista: vw_progreso_clinico (filtrada por terapeuta o global)
CREATE OR REPLACE PROCEDURE public.sp_consultar_progreso_clinico(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- Vista: vw_resultados_instrumentos (filtrada por terapeuta o global)
CREATE OR REPLACE PROCEDURE public.sp_consultar_resultados_instrumentos(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- ----------------------------------------------------------------------------
-- 3. Stored Procedures con TABLAS TEMPORALES (mínimo 3 exigidos — 4 creados)
-- ----------------------------------------------------------------------------

-- SP Temporal #1: Ranking de desempeño y carga clínica por terapeuta
CREATE OR REPLACE PROCEDURE public.sp_reporte_ranking_terapeutas(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- SP Temporal #2: Evolución longitudinal de instrumentos psicométricos (LAG + AVG OVER)
CREATE OR REPLACE PROCEDURE public.sp_reporte_evolucion_longitudinal(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- SP Temporal #3: Consolidación de avance de planes terapéuticos y objetivos
CREATE OR REPLACE PROCEDURE public.sp_reporte_avance_planes(
    IN p_id_terapeuta integer,
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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

-- SP Temporal #4: Indicadores agregados anonimizados (SIN PII — ideal para Admin)
CREATE OR REPLACE PROCEDURE public.sp_reporte_indicadores_anonimizados(
    INOUT p_cursor refcursor,
    OUT p_mensaje character varying
)
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
