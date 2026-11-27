-- ============================================================================
-- Fase 3 (05): Datos semilla coherentes y no triviales (>= 10 por dominio)
-- Script idempotente: puede re-ejecutarse sin duplicar registros.
-- Sistema de Gestión Clínica (Equipo 01)
-- ============================================================================

BEGIN;

-- Contexto de auditoría para la carga semilla (usuario Admin = 1)
SELECT set_config('app.current_user_id', '1', true);
SELECT set_config('app.client_ip', '127.0.0.1', true);

-- ----------------------------------------------------------------------------
-- 1. Permisos y relación Rol-Permiso (12 permisos)
-- ----------------------------------------------------------------------------
INSERT INTO public.permiso (id_permiso, nombre_permiso, modulo)
VALUES
    (1, 'gestionar_pacientes', 'Pacientes'),
    (2, 'gestionar_terapeutas', 'Terapeutas'),
    (3, 'gestionar_asignaciones', 'Asignaciones'),
    (4, 'ver_agenda_global', 'Sesiones'),
    (5, 'gestionar_sesiones_propias', 'Sesiones'),
    (6, 'ver_agenda_propia', 'Sesiones'),
    (7, 'gestionar_planes_objetivos', 'Planes Terapéuticos'),
    (8, 'aplicar_instrumentos', 'Instrumentos'),
    (9, 'responder_instrumentos', 'Instrumentos'),
    (10, 'gestionar_bitacora_propia', 'Bitácoras'),
    (11, 'ver_alertas_clinicas', 'Alertas'),
    (12, 'ver_auditoria_y_kpis', 'Auditoría')
ON CONFLICT (id_permiso) DO NOTHING;

INSERT INTO public.rol_permiso (id_rol, id_permiso)
VALUES
    -- Administrador (1)
    (1, 1), (1, 2), (1, 3), (1, 4), (1, 11), (1, 12),
    -- Terapeuta (2)
    (2, 5), (2, 7), (2, 8), (2, 11),
    -- Paciente (3)
    (3, 6), (3, 9), (3, 10)
ON CONFLICT (id_rol, id_permiso) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 2. Especialidades por Terapeuta (18 relaciones cubriendo los 11 terapeutas)
-- ----------------------------------------------------------------------------
INSERT INTO public.terapeuta_especialidad (id_terapeuta, id_especialidad)
VALUES
    (1, 1), (1, 2),
    (2, 2), (2, 5),
    (3, 1), (3, 3),
    (4, 4), (4, 6),
    (5, 1), (5, 7),
    (6, 5), (6, 9),
    (7, 2), (7, 8),
    (8, 1),
    (9, 9),
    (10, 10),
    (11, 1), (11, 2)
ON CONFLICT (id_terapeuta, id_especialidad) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 3. Catálogo de Tipos de Alerta (5 tipos)
-- ----------------------------------------------------------------------------
INSERT INTO public.tipo_alerta (id_tipo_alerta, nombre, descripcion)
VALUES
    (1, 'Riesgo Clínico Elevado', 'Puntuación psicométrica por encima del umbral moderado-alto (>= 15 pts).'),
    (2, 'Incremento Sintomático', 'Aumento significativo respecto a la evaluación longitudinal previa.'),
    (3, 'Inasistencia Reiterada', 'Cancelaciones consecutivas que comprometen la adherencia terapéutica.'),
    (4, 'Objetivo Estancado', 'Objetivo terapéutico sin progreso registrado en más de 3 semanas.'),
    (5, 'Seguimiento Prioritario', 'Requiere revisión clínica en la próxima sesión programada.')
ON CONFLICT (id_tipo_alerta) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 4. Planes Terapéuticos (12 planes sobre asignaciones vigentes 1..10, 29, 30)
-- ----------------------------------------------------------------------------
INSERT INTO public.plan_terapeutico (id_plan, id_asignacion, id_estado_plan, fecha_inicio, fecha_fin, descripcion_general)
VALUES
    (1, 1, 1, '2026-08-05', NULL, 'Intervención cognitivo-conductual para manejo de ansiedad laboral y regulación del sueño.'),
    (2, 2, 1, '2026-08-06', NULL, 'Plan de activación conductual y reestructuración cognitiva ante episodios depresivos.'),
    (3, 3, 1, '2026-08-07', NULL, 'Acompañamiento para manejo del estrés académico y prevención de agotamiento.'),
    (4, 4, 1, '2026-08-10', NULL, 'Terapia enfocada en habilidades de comunicación asertiva y límites saludables.'),
    (5, 5, 1, '2026-08-11', NULL, 'Abordaje de síntomas de ansiedad generalizada mediante exposición gradual y mindfulness.'),
    (6, 6, 1, '2026-08-12', NULL, 'Plan de duelo y adaptación emocional tras cambios familiares recientes.'),
    (7, 7, 1, '2026-08-15', NULL, 'Fortalecimiento de autoestima y regulación emocional en contexto universitario.'),
    (8, 8, 1, '2026-08-16', NULL, 'Estrategias de afrontamiento ante insomnio crónico y rumiación nocturna.'),
    (9, 9, 1, '2026-08-17', NULL, 'Intervención sistémica para mejora de dinámicas familiares y autocuidado.'),
    (10, 10, 1, '2026-08-18', NULL, 'Plan de manejo de estrés post-proyecto y recuperación de hábitos saludables.'),
    (11, 29, 1, '2026-10-18', NULL, 'Seguimiento terapéutico para regulación de ansiedad social y rutinas de bienestar.'),
    (12, 30, 1, '2026-10-18', NULL, 'Evaluación longitudinal y fortalecimiento de estrategias de manejo de estrés.')
ON CONFLICT (id_plan) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 5. Objetivos Terapéuticos (16 objetivos vinculados a los 12 planes)
-- ----------------------------------------------------------------------------
INSERT INTO public.objetivo (id_objetivo, id_plan, id_estado_objetivo, nombre, descripcion, fecha_inicio, fecha_meta)
VALUES
    (1, 1, 1, 'Higiene del sueño consistente', 'Mantener horario regular de descanso al menos 5 noches por semana.', '2026-08-05', '2026-11-30'),
    (2, 1, 1, 'Registro diario de pensamientos automáticos', 'Identificar detonantes de ansiedad y aplicar reencuadre cognitivo.', '2026-08-05', '2026-12-15'),
    (3, 2, 1, 'Rutina de activación conductual', 'Realizar 3 actividades placenteras o físicas estructuradas por semana.', '2026-08-06', '2026-11-20'),
    (4, 2, 1, 'Reducción de rumiación vespertina', 'Aplicar técnicas de respiración diafragmática y registro de cierre diario.', '2026-08-13', '2026-12-10'),
    (5, 3, 1, 'Planificación académica sin sobrecarga', 'Dividir entregables en bloques manejables con pausas activas.', '2026-08-07', '2026-11-15'),
    (6, 4, 1, 'Comunicación asertiva en entorno laboral', 'Practicar peticiones claras y límites sin culpa en 2 situaciones semanales.', '2026-08-10', '2026-12-01'),
    (7, 5, 1, 'Práctica guiada de atención plena', 'Completar 10 minutos diarios de mindfulness durante 6 semanas.', '2026-08-11', '2026-11-25'),
    (8, 6, 1, 'Elaboración narrativa del duelo', 'Expresar emociones clave en bitácora semanal y revisar en sesión.', '2026-08-12', '2026-12-20'),
    (9, 7, 1, 'Fortalecimiento de autodiálogo compasivo', 'Sustituir autocrítica rígida por afirmaciones realistas basadas en evidencia.', '2026-08-15', '2026-12-05'),
    (10, 8, 1, 'Desconexión digital previa al descanso', 'Evitar pantallas 45 minutos antes de dormir.', '2026-08-16', '2026-11-18'),
    (11, 9, 1, 'Acuerdos claros de convivencia familiar', 'Establecer una reunión semanal estructurada de comunicación familiar.', '2026-08-17', '2026-12-12'),
    (12, 10, 1, 'Pausas de recuperación durante la jornada', 'Incorporar dos pausas de 10 minutos con estiramiento y respiración.', '2026-08-18', '2026-11-28'),
    (13, 11, 1, 'Exposición gradual a eventos sociales', 'Asistir a una actividad grupal breve por semana aplicando técnicas de calma.', '2026-10-18', '2026-12-20'),
    (14, 11, 1, 'Bitácora emocional de fin de día', 'Registrar intensidad emocional y estrategias utilizadas 4 veces por semana.', '2026-10-18', '2026-12-15'),
    (15, 12, 1, 'Control de estrés ante alta demanda', 'Aplicar técnica de respiración 4-7-8 en picos de tensión laboral.', '2026-10-18', '2026-12-18'),
    (16, 12, 1, 'Seguimiento quincenal con escalas psicométricas', 'Completar evaluaciones longitudinales PHQ-9 y GAD-7 en tiempo y forma.', '2026-10-18', '2026-12-22')
ON CONFLICT (id_objetivo) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 6. Historial de Objetivos (24 registros — incluye logros al 100% que activan trigger)
-- ----------------------------------------------------------------------------
INSERT INTO public.historial_objetivo (id_historial, id_objetivo, porcentaje_avance_registrado, fecha_registro, comentario, registrado_por)
VALUES
    (1, 1, 25.00, '2026-08-19 10:50:00', 'Se establecieron horarios base de descanso entre semana.', 2),
    (2, 1, 65.00, '2026-09-02 10:50:00', 'Cumplimiento de 4 noches constantes; menor latencia de sueño.', 2),
    (3, 1, 100.00, '2026-09-23 10:50:00', 'Meta consolidada durante 3 semanas seguidas.', 2),
    (4, 2, 30.00, '2026-08-26 10:55:00', 'Primeros registros completos de pensamientos automáticos.', 2),
    (5, 2, 70.00, '2026-09-16 10:55:00', 'Aplica reencuadre autónomo antes de reuniones críticas.', 2),
    (6, 3, 40.00, '2026-08-20 11:50:00', 'Inició caminatas matutinas 2 días por semana.', 2),
    (7, 3, 80.00, '2026-09-10 11:50:00', 'Mantiene 3 actividades semanales y reporta mejor energía.', 2),
    (8, 4, 35.00, '2026-08-27 11:55:00', 'Practica respiración guiada antes de cenar.', 2),
    (9, 5, 50.00, '2026-08-28 16:50:00', 'Uso de matriz de prioridades redujo entregas de último minuto.', 2),
    (10, 5, 100.00, '2026-09-18 16:50:00', 'Logro completo del objetivo y cierre exitoso del plan 3.', 2),
    (11, 6, 45.00, '2026-08-24 09:50:00', 'Primera conversación asertiva exitosa con su equipo.', 3),
    (12, 6, 85.00, '2026-09-14 09:50:00', 'Mantiene límites saludables sin escalamiento emocional.', 3),
    (13, 7, 50.00, '2026-08-25 10:50:00', 'Completa 5 días/semana de mindfulness guiado.', 3),
    (14, 7, 90.00, '2026-09-15 10:50:00', 'Disminución notable en episodios de inquietud diurna.', 3),
    (15, 8, 40.00, '2026-08-26 11:50:00', 'Apertura emocional constante en sesiones y bitácora.', 3),
    (16, 9, 55.00, '2026-08-29 16:50:00', 'Reconoce autocrítica temprana y la reformula.', 4),
    (17, 10, 60.00, '2026-08-30 17:50:00', 'Reduce uso de celular nocturno 4 noches por semana.', 4),
    (18, 11, 50.00, '2026-09-01 18:50:00', 'Primera reunión familiar estructurada con acuerdos escritos.', 4),
    (19, 12, 75.00, '2026-09-03 09:50:00', 'Pausas activas integradas en calendario laboral.', 5),
    (20, 13, 30.00, '2026-10-25 15:00:00', 'Asistió a evento breve con manejo adecuado de respiración.', 50),
    (21, 14, 60.00, '2026-11-01 15:00:00', 'Completó 4 registros semanales en bitácora emocional.', 50),
    (22, 15, 45.00, '2026-10-26 15:10:00', 'Aplica respiración 4-7-8 en momentos de presión laboral.', 50),
    (23, 15, 75.00, '2026-11-09 15:10:00', 'Reporta recuperación más rápida tras jornadas demandantes.', 50),
    (24, 16, 50.00, '2026-11-09 15:15:00', 'Respondió evaluación inicial y seguimiento quincenal.', 50)
ON CONFLICT (id_historial) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 7. Instrumentos Psicométricos Simulados y Dimensiones (4 instrumentos, 10 dimensiones)
-- ----------------------------------------------------------------------------
INSERT INTO public.instrumento (id_instrumento, nombre, descripcion, estado, version)
VALUES
    (1, 'PHQ-9 (Depresión)', 'Cuestionario simulado de 9 ítems para seguimiento longitudinal de síntomas depresivos (0-27).', 'Activo', 'v1.0'),
    (2, 'GAD-7 (Ansiedad)', 'Escala simulada de 7 ítems para evaluación de ansiedad generalizada (0-21).', 'Activo', 'v1.0'),
    (3, 'PSS-10 (Estrés Percibido)', 'Escala simulada de percepción de estrés cotidiano y afrontamiento (0-40).', 'Activo', 'v1.0'),
    (4, 'WHO-5 (Bienestar)', 'Índice simulado de bienestar emocional positivo y vitalidad (0-25).', 'Activo', 'v1.0')
ON CONFLICT (id_instrumento) DO NOTHING;

INSERT INTO public.dimension_instrumento (id_dimension, id_instrumento, nombre_dimension)
VALUES
    (1, 1, 'Ánimo Depresivo Global'),
    (2, 1, 'Anhedonia y Energía'),
    (3, 1, 'Alteración de Sueño'),
    (4, 2, 'Ansiedad Cognitiva'),
    (5, 2, 'Tensión Somática'),
    (6, 3, 'Estrés Cotidiano'),
    (7, 3, 'Sobrecarga Emocional'),
    (8, 3, 'Afrontamiento Percibido'),
    (9, 4, 'Vitalidad Diaria'),
    (10, 4, 'Calidad de Descanso')
ON CONFLICT (id_dimension) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 8. Aplicaciones de Instrumentos (16 aplicaciones longitudinales en varias fechas)
-- ----------------------------------------------------------------------------
INSERT INTO public.aplicacion_instrumento (id_aplicacion, id_instrumento, id_paciente, id_terapeuta, fecha_asignacion, fecha_respuesta, estado, id_documento_mongo)
VALUES
    (1, 1, 1, 1, '2026-08-05 09:00:00', '2026-08-05 18:00:00', 'Completada', NULL),
    (2, 1, 1, 1, '2026-08-19 09:00:00', '2026-08-19 19:00:00', 'Completada', NULL),
    (3, 1, 1, 1, '2026-09-02 09:00:00', '2026-09-02 18:30:00', 'Completada', NULL),
    (4, 2, 2, 1, '2026-08-06 10:00:00', '2026-08-06 17:00:00', 'Completada', NULL),
    (5, 2, 2, 1, '2026-08-20 10:00:00', '2026-08-20 17:30:00', 'Completada', NULL),
    (6, 3, 3, 1, '2026-08-07 15:00:00', '2026-08-07 20:00:00', 'Completada', NULL),
    (7, 3, 3, 1, '2026-08-21 15:00:00', '2026-08-21 20:15:00', 'Completada', NULL),
    (8, 2, 4, 2, '2026-08-10 08:30:00', '2026-08-10 14:00:00', 'Completada', NULL),
    (9, 2, 4, 2, '2026-08-24 08:30:00', '2026-08-24 14:30:00', 'Completada', NULL),
    (10, 1, 5, 2, '2026-08-11 09:30:00', '2026-08-11 16:00:00', 'Completada', NULL),
    (11, 1, 5, 2, '2026-08-25 09:30:00', '2026-08-25 16:10:00', 'Completada', NULL),
    (12, 4, 7, 3, '2026-08-15 15:00:00', '2026-08-15 19:00:00', 'Completada', NULL),
    (13, 2, 29, 11, '2026-10-19 10:00:00', '2026-10-19 18:00:00', 'Completada', NULL),
    (14, 2, 29, 11, '2026-11-02 10:00:00', '2026-11-02 18:30:00', 'Completada', NULL),
    (15, 1, 33, 11, '2026-10-20 11:00:00', '2026-10-20 19:00:00', 'Completada', NULL),
    (16, 1, 33, 11, '2026-11-03 11:00:00', '2026-11-03 19:15:00', 'Completada', NULL)
ON CONFLICT (id_aplicacion) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 9. Resultados de Instrumentos (24 resultados — puntuaciones >= 15 disparan trigger de alerta!)
-- ----------------------------------------------------------------------------
INSERT INTO public.resultado_instrumento (id_resultado, id_aplicacion, id_dimension, puntuacion_bruta, fecha_calculo)
VALUES
    -- Paciente 1 (Paola González): PHQ-9 mejora longitudinal 17 -> 13 -> 8
    (1, 1, 1, 17.00, '2026-08-05 18:05:00'),
    (2, 1, 2, 11.00, '2026-08-05 18:05:00'),
    (3, 2, 1, 13.00, '2026-08-19 19:05:00'),
    (4, 2, 2, 8.00,  '2026-08-19 19:05:00'),
    (5, 3, 1, 8.00,  '2026-09-02 18:35:00'),
    (6, 3, 2, 5.00,  '2026-09-02 18:35:00'),
    -- Paciente 2 (Andrés Sánchez): GAD-7 mejora 16 -> 11
    (7, 4, 4, 16.00, '2026-08-06 17:05:00'),
    (8, 4, 5, 12.00, '2026-08-06 17:05:00'),
    (9, 5, 4, 11.00, '2026-08-20 17:35:00'),
    (10, 5, 5, 8.00, '2026-08-20 17:35:00'),
    -- Paciente 3 (Fernanda Taha): PSS-10 deterioro 14 -> 19 (dispara alerta!)
    (11, 6, 6, 14.00, '2026-08-07 20:05:00'),
    (12, 7, 6, 19.00, '2026-08-21 20:20:00'),
    -- Paciente 4 (Miguel Gómez): GAD-7 mejora 15 -> 9
    (13, 8, 4, 15.00, '2026-08-10 14:05:00'),
    (14, 9, 4, 9.00,  '2026-08-24 14:35:00'),
    -- Paciente 5 (Lucía Pérez): PHQ-9 deterioro 12 -> 18 (dispara alerta!)
    (15, 10, 1, 12.00, '2026-08-11 16:05:00'),
    (16, 11, 1, 18.00, '2026-08-25 16:15:00'),
    -- Paciente 7 (Valeria Ramírez): WHO-5 bienestar 16 -> alto bienestar
    (17, 12, 9, 14.00, '2026-08-15 19:05:00'),
    (18, 12, 10, 13.00, '2026-08-15 19:05:00'),
    -- Paciente 29 (Alma Solis, Terapeuta 11 Paola): GAD-7 mejora 16 -> 11
    (19, 13, 4, 16.00, '2026-10-19 18:05:00'),
    (20, 14, 4, 11.00, '2026-11-02 18:35:00'),
    -- Paciente 33 (Carlos Aguilar, Terapeuta 11 Paola): PHQ-9 mejora 15 -> 10
    (21, 15, 1, 15.00, '2026-10-20 19:05:00'),
    (22, 15, 3, 12.00, '2026-10-20 19:05:00'),
    (23, 16, 1, 10.00, '2026-11-03 19:20:00'),
    (24, 16, 3, 7.00,  '2026-11-03 19:20:00')
ON CONFLICT (id_resultado) DO NOTHING;

-- ----------------------------------------------------------------------------
-- 10. Alertas complementarias (asegurando >= 10 alertas en dominio, sumando
-- las generadas automáticamente por trg_alerta_riesgo_instrumento)
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    IF (SELECT COUNT(*) FROM public.alerta) < 10 THEN
        INSERT INTO public.alerta (id_paciente, id_terapeuta, id_tipo_alerta, descripcion, atendida)
        VALUES
            (3, 1, 3, 'Sesión cancelada consecutiva; confirmar disponibilidad para reprogramación.', FALSE),
            (6, 2, 4, 'Objetivo de elaboración de duelo sin actualización en los últimos 21 días.', FALSE),
            (8, 3, 5, 'Revisar adherencia a desconexión digital en la próxima cita programada.', FALSE),
            (29, 11, 5, 'Validar respuesta positiva tras reducción de ansiedad en evaluación GAD-7.', FALSE);
    END IF;
END
$$;

-- ----------------------------------------------------------------------------
-- 11. Sincronizar secuencias para evitar choques al insertar desde la app
-- ----------------------------------------------------------------------------
SELECT setval('public.permiso_id_permiso_seq', COALESCE((SELECT MAX(id_permiso) FROM public.permiso), 1), true);
SELECT setval('public.tipo_alerta_id_tipo_alerta_seq', COALESCE((SELECT MAX(id_tipo_alerta) FROM public.tipo_alerta), 1), true);
SELECT setval('public.plan_terapeutico_id_plan_seq', COALESCE((SELECT MAX(id_plan) FROM public.plan_terapeutico), 1), true);
SELECT setval('public.objetivo_id_objetivo_seq', COALESCE((SELECT MAX(id_objetivo) FROM public.objetivo), 1), true);
SELECT setval('public.historial_objetivo_id_historial_seq', COALESCE((SELECT MAX(id_historial) FROM public.historial_objetivo), 1), true);
SELECT setval('public.instrumento_id_instrumento_seq', COALESCE((SELECT MAX(id_instrumento) FROM public.instrumento), 1), true);
SELECT setval('public.dimension_instrumento_id_dimension_seq', COALESCE((SELECT MAX(id_dimension) FROM public.dimension_instrumento), 1), true);
SELECT setval('public.aplicacion_instrumento_id_aplicacion_seq', COALESCE((SELECT MAX(id_aplicacion) FROM public.aplicacion_instrumento), 1), true);
SELECT setval('public.resultado_instrumento_id_resultado_seq', COALESCE((SELECT MAX(id_resultado) FROM public.resultado_instrumento), 1), true);
SELECT setval('public.alerta_id_alerta_seq', COALESCE((SELECT MAX(id_alerta) FROM public.alerta), 1), true);
SELECT setval('public.auditoria_id_auditoria_seq', COALESCE((SELECT MAX(id_auditoria) FROM public.auditoria), 1), true);

COMMIT;
