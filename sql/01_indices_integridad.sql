-- ============================================================================
-- Fase 3 (01): Índices de rendimiento y restricciones adicionales de integridad
-- Sistema de Gestión Clínica (Equipo 01) — PostgreSQL (esquema public, 3FN)
-- ============================================================================

-- Restricción de integridad horaria en sesiones
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'chk_sesion_horario_valido'
    ) THEN
        ALTER TABLE public.sesion
            ADD CONSTRAINT chk_sesion_horario_valido CHECK (hora_fin > hora_inicio);
    END IF;
END
$$;

-- Índices sobre llaves foráneas y columnas de filtrado frecuente
CREATE INDEX IF NOT EXISTS idx_sesion_fecha_estado
    ON public.sesion (fecha DESC, id_estado_sesion);

CREATE INDEX IF NOT EXISTS idx_sesion_asignacion
    ON public.sesion (id_asignacion);

CREATE INDEX IF NOT EXISTS idx_asignacion_terapeuta_estado
    ON public.asignacion_terapeuta_paciente (id_terapeuta, id_estado_asignacion);

CREATE INDEX IF NOT EXISTS idx_asignacion_paciente_estado
    ON public.asignacion_terapeuta_paciente (id_paciente, id_estado_asignacion);

CREATE INDEX IF NOT EXISTS idx_auditoria_fecha_desc
    ON public.auditoria (fecha_hora DESC);

CREATE INDEX IF NOT EXISTS idx_alerta_terapeuta_atendida
    ON public.alerta (id_terapeuta, atendida);

CREATE INDEX IF NOT EXISTS idx_historial_objetivo_fecha
    ON public.historial_objetivo (id_objetivo, fecha_registro DESC);

CREATE INDEX IF NOT EXISTS idx_aplicacion_paciente_fecha
    ON public.aplicacion_instrumento (id_paciente, fecha_respuesta DESC);

CREATE INDEX IF NOT EXISTS idx_resultado_aplicacion_dimension
    ON public.resultado_instrumento (id_aplicacion, id_dimension);
