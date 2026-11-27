-- ============================================================================
-- Fase 3 (06): Evidencia Completa de JOINs y Consultas SQL Avanzadas
-- Sistema de Gestión Clínica (Equipo 01) — Bases de Datos Avanzadas
--
-- Incluye de forma independiente y documentada TODOS los requisitos exigidos:
--   1. INNER JOIN
--   2. LEFT JOIN
--   3. RIGHT JOIN
--   4. FULL OUTER JOIN
--   5. CROSS JOIN
--   6. SELF JOIN
--   7. JOIN de tres o más tablas (6 tablas)
--   8. Funciones de agregación: COUNT, SUM, AVG, MIN, MAX
--   9. Subconsultas (>= 2: escalar + correlacionada / IN)
--  10. Expresiones de Tabla Comunes (CTE con WITH encadenadas)
--  11. Funciones de ventana: ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD, SUM OVER, AVG OVER
--  12. Transacciones explícitas con COMMIT y ROLLBACK + SAVEPOINT
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. INNER JOIN
-- Propósito: Obtener únicamente los pacientes activos que cuentan con una
-- asignación vigente, mostrando su fecha de vinculación.
-- ----------------------------------------------------------------------------
SELECT
    p.id_paciente,
    p.nombre || ' ' || p.apellido_paterno AS paciente,
    a.id_asignacion,
    a.fecha_inicio
FROM public.paciente p
INNER JOIN public.asignacion_terapeuta_paciente a
    ON p.id_paciente = a.id_paciente
WHERE p.id_estado_paciente = 1
  AND a.id_estado_asignacion = 1
ORDER BY a.fecha_inicio DESC
LIMIT 10;

-- ----------------------------------------------------------------------------
-- 2. LEFT JOIN
-- Propósito: Listar TODOS los pacientes activos incluyendo aquellos que aún
-- NO tienen un terapeuta asignado (detecta cartera pendiente de asignación).
-- ----------------------------------------------------------------------------
SELECT
    p.id_paciente,
    p.nombre || ' ' || p.apellido_paterno AS paciente,
    COALESCE(a.id_asignacion::text, 'Sin asignar') AS estatus_asignacion
FROM public.paciente p
LEFT JOIN public.asignacion_terapeuta_paciente a
    ON p.id_paciente = a.id_paciente
   AND a.id_estado_asignacion = 1
WHERE p.id_estado_paciente = 1
ORDER BY a.id_asignacion NULLS FIRST, p.id_paciente ASC
LIMIT 15;

-- ----------------------------------------------------------------------------
-- 3. RIGHT JOIN
-- Propósito: Mostrar todas las especialidades del catálogo clínico junto con
-- los terapeutas vinculados, asegurando visibilidad incluso de especialidades
-- sin demanda cubierta.
-- ----------------------------------------------------------------------------
SELECT
    e.id_especialidad,
    e.nombre_especialidad,
    COUNT(te.id_terapeuta) AS terapeutas_disponibles
FROM public.terapeuta_especialidad te
RIGHT JOIN public.especialidad e
    ON te.id_especialidad = e.id_especialidad
GROUP BY e.id_especialidad, e.nombre_especialidad
ORDER BY terapeutas_disponibles DESC, e.nombre_especialidad ASC;

-- ----------------------------------------------------------------------------
-- 4. FULL OUTER JOIN
-- Propósito: Conciliar todas las sesiones registradas contra las referencias
-- de resumen SOAP (referencia_resumen), evidenciando tanto sesiones sin resumen
-- aún documentado como eventuales referencias huérfanas.
-- ----------------------------------------------------------------------------
SELECT
    s.id_sesion,
    s.fecha,
    rr.id_referencia,
    COALESCE(rr.id_documento_mongo, 'Pendiente de documentación SOAP') AS documento_mongo
FROM public.sesion s
FULL OUTER JOIN public.referencia_resumen rr
    ON s.id_sesion = rr.id_sesion
ORDER BY s.fecha DESC NULLS LAST
LIMIT 15;

-- ----------------------------------------------------------------------------
-- 5. CROSS JOIN
-- Propósito: Generar la matriz completa de combinaciones posibles entre cada
-- modalidad de sesión (Presencial/Virtual) y cada instrumento psicométrico
-- activo para planificar cobertura de evaluaciones.
-- ----------------------------------------------------------------------------
SELECT
    m.nombre AS modalidad,
    i.nombre AS instrumento,
    i.version
FROM public.modalidad_sesion m
CROSS JOIN public.instrumento i
ORDER BY m.id_modalidad, i.id_instrumento;

-- ----------------------------------------------------------------------------
-- 6. SELF JOIN
-- Propósito: Identificar pares distintos de pacientes atendidos por el MISMO
-- terapeuta vigente (útil para análisis de carga compartida y grupos clínicos).
-- ----------------------------------------------------------------------------
SELECT
    a1.id_terapeuta,
    p1.nombre || ' ' || p1.apellido_paterno AS paciente_a,
    p2.nombre || ' ' || p2.apellido_paterno AS paciente_b
FROM public.asignacion_terapeuta_paciente a1
JOIN public.asignacion_terapeuta_paciente a2
    ON a1.id_terapeuta = a2.id_terapeuta
   AND a1.id_paciente < a2.id_paciente
   AND a1.id_estado_asignacion = 1
   AND a2.id_estado_asignacion = 1
JOIN public.paciente p1 ON a1.id_paciente = p1.id_paciente
JOIN public.paciente p2 ON a2.id_paciente = p2.id_paciente
ORDER BY a1.id_terapeuta, paciente_a
LIMIT 15;

-- ----------------------------------------------------------------------------
-- 7. JOIN de tres o más tablas (6 tablas relacionadas)
-- Propósito: Reconstruir la trazabilidad clínica completa de planes,
-- objetivos, último avance, terapeuta responsable y paciente.
-- ----------------------------------------------------------------------------
SELECT
    p.nombre || ' ' || p.apellido_paterno AS paciente,
    t.nombre || ' ' || t.apellido_paterno AS terapeuta,
    ep.nombre AS estado_plan,
    o.nombre AS objetivo,
    eo.nombre AS estado_objetivo,
    COALESCE(MAX(h.porcentaje_avance_registrado), 0.00) AS max_avance_pct
FROM public.plan_terapeutico pt
JOIN public.estado_plan ep ON pt.id_estado_plan = ep.id_estado_plan
JOIN public.asignacion_terapeuta_paciente a ON pt.id_asignacion = a.id_asignacion
JOIN public.paciente p ON a.id_paciente = p.id_paciente
JOIN public.terapeuta t ON a.id_terapeuta = t.id_terapeuta
JOIN public.objetivo o ON pt.id_plan = o.id_plan
JOIN public.estado_objetivo eo ON o.id_estado_objetivo = eo.id_estado_objetivo
LEFT JOIN public.historial_objetivo h ON o.id_objetivo = h.id_objetivo
GROUP BY p.nombre, p.apellido_paterno, t.nombre, t.apellido_paterno, ep.nombre, o.nombre, eo.nombre
ORDER BY max_avance_pct DESC, paciente ASC
LIMIT 15;

-- ----------------------------------------------------------------------------
-- 8. Funciones de Agregación: COUNT, SUM, AVG, MIN, MAX
-- Propósito: Estadísticas globales de puntuaciones psicométricas por
-- instrumento aplicado.
-- ----------------------------------------------------------------------------
SELECT
    i.nombre AS instrumento,
    COUNT(ri.id_resultado) AS total_mediciones,
    SUM(ri.puntuacion_bruta) AS suma_puntuaciones,
    ROUND(AVG(ri.puntuacion_bruta), 2) AS promedio_puntuacion,
    MIN(ri.puntuacion_bruta) AS puntuacion_minima,
    MAX(ri.puntuacion_bruta) AS puntuacion_maxima
FROM public.instrumento i
JOIN public.aplicacion_instrumento ai ON i.id_instrumento = ai.id_instrumento
JOIN public.resultado_instrumento ri ON ai.id_aplicacion = ri.id_aplicacion
GROUP BY i.nombre
ORDER BY promedio_puntuacion DESC;

-- ----------------------------------------------------------------------------
-- 9A. Subconsulta #1 (Escalar en WHERE)
-- Propósito: Detectar resultados de instrumentos cuya puntuación bruta supera
-- el promedio global de todas las mediciones de la clínica.
-- ----------------------------------------------------------------------------
SELECT
    v.paciente,
    v.instrumento,
    v.dimension_evaluada,
    v.puntuacion_bruta
FROM public.vw_resultados_instrumentos v
WHERE v.puntuacion_bruta > (
    SELECT AVG(puntuacion_bruta) FROM public.resultado_instrumento
)
ORDER BY v.puntuacion_bruta DESC;

-- ----------------------------------------------------------------------------
-- 9B. Subconsulta #2 (Correlacionada con EXISTS / IN)
-- Propósito: Identificar terapeutas activos que tienen al menos una alerta
-- clínica pendiente de atención para sus pacientes.
-- ----------------------------------------------------------------------------
SELECT
    t.id_terapeuta,
    t.nombre || ' ' || t.apellido_paterno AS terapeuta,
    t.cedula_profesional,
    (
        SELECT COUNT(*)
        FROM public.alerta al
        WHERE al.id_terapeuta = t.id_terapeuta
          AND al.atendida = FALSE
    ) AS alertas_pendientes
FROM public.terapeuta t
WHERE t.id_estado_terapeuta = 1
  AND EXISTS (
      SELECT 1
      FROM public.alerta al
      WHERE al.id_terapeuta = t.id_terapeuta
        AND al.atendida = FALSE
  )
ORDER BY alertas_pendientes DESC;

-- ----------------------------------------------------------------------------
-- 10. Expresiones de Tabla Comunes (CTE encadenadas con WITH)
-- Propósito: Calcular la carga semanal y tasa de finalización por terapeuta
-- combinando sesiones y planes activos.
-- ----------------------------------------------------------------------------
WITH sesiones_por_terapeuta AS (
    SELECT
        a.id_terapeuta,
        COUNT(s.id_sesion) AS total_sesiones,
        COUNT(CASE WHEN s.id_estado_sesion = 2 THEN 1 END) AS completadas
    FROM public.asignacion_terapeuta_paciente a
    LEFT JOIN public.sesion s ON a.id_asignacion = s.id_asignacion
    GROUP BY a.id_terapeuta
),
planes_por_terapeuta AS (
    SELECT
        a.id_terapeuta,
        COUNT(pt.id_plan) AS total_planes
    FROM public.asignacion_terapeuta_paciente a
    LEFT JOIN public.plan_terapeutico pt ON a.id_asignacion = pt.id_asignacion
    GROUP BY a.id_terapeuta
)
SELECT
    t.nombre || ' ' || t.apellido_paterno AS terapeuta,
    COALESCE(st.total_sesiones, 0) AS total_sesiones,
    COALESCE(st.completadas, 0) AS completadas,
    COALESCE(pt.total_planes, 0) AS planes_terapeuticos,
    CASE
        WHEN COALESCE(st.total_sesiones, 0) = 0 THEN 0.00
        ELSE ROUND((st.completadas::numeric * 100.0) / st.total_sesiones, 2)
    END AS tasa_completadas_pct
FROM public.terapeuta t
LEFT JOIN sesiones_por_terapeuta st ON t.id_terapeuta = st.id_terapeuta
LEFT JOIN planes_por_terapeuta pt ON t.id_terapeuta = pt.id_terapeuta
WHERE t.id_estado_terapeuta = 1
ORDER BY tasa_completadas_pct DESC, total_sesiones DESC;

-- ----------------------------------------------------------------------------
-- 11A. Funciones de Ventana: ROW_NUMBER, RANK, DENSE_RANK
-- Propósito: Clasificar a los terapeutas según su volumen de sesiones
-- completadas mostrando las diferencias entre numeración secuencial y empates.
-- ----------------------------------------------------------------------------
WITH conteo AS (
    SELECT
        t.nombre || ' ' || t.apellido_paterno AS terapeuta,
        COUNT(CASE WHEN s.id_estado_sesion = 2 THEN 1 END) AS sesiones_completadas
    FROM public.terapeuta t
    LEFT JOIN public.asignacion_terapeuta_paciente a ON t.id_terapeuta = a.id_terapeuta
    LEFT JOIN public.sesion s ON a.id_asignacion = s.id_asignacion
    WHERE t.id_estado_terapeuta = 1
    GROUP BY t.id_terapeuta, t.nombre, t.apellido_paterno
)
SELECT
    terapeuta,
    sesiones_completadas,
    ROW_NUMBER() OVER (ORDER BY sesiones_completadas DESC, terapeuta ASC) AS fila_num,
    RANK() OVER (ORDER BY sesiones_completadas DESC) AS ranking,
    DENSE_RANK() OVER (ORDER BY sesiones_completadas DESC) AS ranking_denso
FROM conteo
ORDER BY fila_num;

-- ----------------------------------------------------------------------------
-- 11B. Funciones de Ventana Longitudinales: LAG, LEAD, SUM OVER, AVG OVER
-- Propósito: Evaluar evolución longitudinal de puntuaciones por paciente e
-- instrumento (puntuación anterior, siguiente, acumulado y promedio móvil).
-- ----------------------------------------------------------------------------
SELECT
    p.nombre || ' ' || p.apellido_paterno AS paciente,
    i.nombre AS instrumento,
    di.nombre_dimension AS dimension,
    ai.fecha_respuesta::date AS fecha,
    ri.puntuacion_bruta AS puntaje_actual,
    LAG(ri.puntuacion_bruta) OVER w AS puntaje_anterior,
    LEAD(ri.puntuacion_bruta) OVER w AS puntaje_siguiente,
    SUM(ri.puntuacion_bruta) OVER (
        PARTITION BY ai.id_paciente, i.id_instrumento, di.id_dimension
        ORDER BY ai.fecha_respuesta
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS suma_acumulada,
    ROUND(AVG(ri.puntuacion_bruta) OVER (
        PARTITION BY ai.id_paciente, i.id_instrumento, di.id_dimension
    ), 2) AS promedio_paciente
FROM public.aplicacion_instrumento ai
JOIN public.paciente p ON ai.id_paciente = p.id_paciente
JOIN public.instrumento i ON ai.id_instrumento = i.id_instrumento
JOIN public.resultado_instrumento ri ON ai.id_aplicacion = ri.id_aplicacion
JOIN public.dimension_instrumento di ON ri.id_dimension = di.id_dimension
WINDOW w AS (
    PARTITION BY ai.id_paciente, i.id_instrumento, di.id_dimension
    ORDER BY ai.fecha_respuesta ASC
)
ORDER BY paciente, instrumento, dimension, fecha;

-- ----------------------------------------------------------------------------
-- 12. Evidencia de Transacciones: BEGIN ... SAVEPOINT ... ROLLBACK y COMMIT
-- Propósito: Demostrar control transaccional explícito sin dejar basura en BD.
-- ----------------------------------------------------------------------------
BEGIN;
    INSERT INTO public.tipo_alerta (nombre, descripcion)
    VALUES ('Prueba Transaccional Rollback', 'Registro temporal para demostrar ROLLBACK.');

    SAVEPOINT sp_antes_de_error;

    UPDATE public.tipo_alerta
    SET descripcion = 'Modificación descartada por ROLLBACK TO SAVEPOINT'
    WHERE nombre = 'Prueba Transaccional Rollback';

    ROLLBACK TO SAVEPOINT sp_antes_de_error;
ROLLBACK;

BEGIN;
    -- Transacción de solo verificación con COMMIT limpio
    SELECT COUNT(*) AS alertas_activas_tras_prueba FROM public.vw_alertas_activas;
COMMIT;
