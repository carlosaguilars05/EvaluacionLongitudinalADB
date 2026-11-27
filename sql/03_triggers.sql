-- ============================================================================
-- Fase 3 (03): Triggers de Auditoría (>= 1 por entidad crítica) +
-- Triggers de Integridad y Lógica Reactiva (Total: 9 triggers en PostgreSQL)
-- Sistema de Gestión Clínica (Equipo 01)
-- ============================================================================

-- ----------------------------------------------------------------------------
-- A. Función genérica de auditoría para entidades críticas
-- Lee usuario e IP desde variables de sesión transaccionales (app.current_user_id
-- y app.client_ip) establecidas por sp_establecer_contexto_auditoria.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_auditoria_clinica()
RETURNS trigger
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

-- Trigger 1: Auditoría de Pacientes
DROP TRIGGER IF EXISTS trg_auditoria_paciente ON public.paciente;
CREATE TRIGGER trg_auditoria_paciente
    AFTER INSERT OR UPDATE ON public.paciente
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Pacientes', 'id_paciente');

-- Trigger 2: Auditoría de Terapeutas
DROP TRIGGER IF EXISTS trg_auditoria_terapeuta ON public.terapeuta;
CREATE TRIGGER trg_auditoria_terapeuta
    AFTER INSERT OR UPDATE ON public.terapeuta
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Terapeutas', 'id_terapeuta');

-- Trigger 3: Auditoría de Asignaciones Terapeuta-Paciente
DROP TRIGGER IF EXISTS trg_auditoria_asignacion ON public.asignacion_terapeuta_paciente;
CREATE TRIGGER trg_auditoria_asignacion
    AFTER INSERT OR UPDATE ON public.asignacion_terapeuta_paciente
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Asignaciones', 'id_asignacion');

-- Trigger 4: Auditoría de Sesiones
DROP TRIGGER IF EXISTS trg_auditoria_sesion ON public.sesion;
CREATE TRIGGER trg_auditoria_sesion
    AFTER INSERT OR UPDATE ON public.sesion
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Sesiones', 'id_sesion');

-- Trigger 5: Auditoría de Planes Terapéuticos
DROP TRIGGER IF EXISTS trg_auditoria_plan_terapeutico ON public.plan_terapeutico;
CREATE TRIGGER trg_auditoria_plan_terapeutico
    AFTER INSERT OR UPDATE ON public.plan_terapeutico
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Planes Terapéuticos', 'id_plan');

-- Trigger 6: Auditoría de Objetivos Terapéuticos
DROP TRIGGER IF EXISTS trg_auditoria_objetivo ON public.objetivo;
CREATE TRIGGER trg_auditoria_objetivo
    AFTER INSERT OR UPDATE ON public.objetivo
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_auditoria_clinica('Objetivos', 'id_objetivo');

-- ----------------------------------------------------------------------------
-- B. Trigger 7 (Integridad): Validar horario y anti-empalme a nivel BD en sesion
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_validar_sesion_integridad()
RETURNS trigger
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

DROP TRIGGER IF EXISTS trg_validar_sesion_integridad ON public.sesion;
CREATE TRIGGER trg_validar_sesion_integridad
    BEFORE INSERT OR UPDATE ON public.sesion
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_validar_sesion_integridad();

-- ----------------------------------------------------------------------------
-- C. Trigger 8 (Lógica Reactiva): Alerta automática por puntuación clínica elevada
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_alerta_riesgo_instrumento()
RETURNS trigger
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

DROP TRIGGER IF EXISTS trg_alerta_riesgo_instrumento ON public.resultado_instrumento;
CREATE TRIGGER trg_alerta_riesgo_instrumento
    AFTER INSERT ON public.resultado_instrumento
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_alerta_riesgo_instrumento();

-- ----------------------------------------------------------------------------
-- D. Trigger 9 (Lógica Reactiva): Avance 100% marca objetivo Logrado y cierra plan
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.fn_progreso_reactivo_objetivo()
RETURNS trigger
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

DROP TRIGGER IF EXISTS trg_progreso_reactivo_objetivo ON public.historial_objetivo;
CREATE TRIGGER trg_progreso_reactivo_objetivo
    AFTER INSERT ON public.historial_objetivo
    FOR EACH ROW
    EXECUTE FUNCTION public.fn_progreso_reactivo_objetivo();
