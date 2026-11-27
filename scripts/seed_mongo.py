#!/usr/bin/env python3
"""
Poblado idempotente de las 4 colecciones clínicas en MongoDB (Atlas GCP o local)
y sincronización coordinada con PostgreSQL vía Stored Procedures (Reglas R1 y R5).

Colecciones pobladas (>= 10 documentos cada una):
  1. cuestionarios_instrumentos  (4 plantillas dinámicas + 16 respuestas sincronizadas con PG)
  2. bitacoras_emocionales       (18 entradas longitudinales enlazadas en referencia_bitacora)
  3. resumenes_sesion_soap       (12 transcripciones + notas SOAP enlazadas en referencia_resumen)
  4. historial_ediciones_clinicas (14 versiones y notas clínicas extensas del terapeuta)

Uso:
    python scripts/seed_mongo.py
"""

from __future__ import annotations

from datetime import datetime, timezone
import os
import sys
from pathlib import Path

import psycopg
from dotenv import load_dotenv

ROOT = Path(__file__).resolve().parent.parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

load_dotenv(ROOT / ".env")

import mongo_db  # noqa: E402


PLANTILLAS_INSTRUMENTOS = [
    {
        "tipo_documento": "plantilla",
        "id_instrumento_pg": 1,
        "codigo": "PHQ-9",
        "nombre": "PHQ-9 (Depresión)",
        "version": "v1.0",
        "descripcion": "Cuestionario psicométrico simulado de seguimiento longitudinal (0 a 3 por ítem).",
        "escala": {
            "min": 0,
            "max": 3,
            "etiquetas": ["0 - Ningún día", "1 - Varios días", "2 - Más de la mitad de los días", "3 - Casi todos los días"],
        },
        "umbrales": {"leve": 5, "moderado": 10, "alerta_clinica": 15},
        "preguntas": [
            {"codigo": "P1", "texto": "Poco interés o placer en hacer actividades cotidianas", "id_dimension_pg": 2, "tipo": "likert"},
            {"codigo": "P2", "texto": "Sentirse decaído(a), deprimido(a) o sin esperanza", "id_dimension_pg": 1, "tipo": "likert"},
            {"codigo": "P3", "texto": "Dificultad para conciliar o mantener el sueño, o dormir demasiado", "id_dimension_pg": 3, "tipo": "likert"},
            {"codigo": "P4", "texto": "Sentirse cansado(a) o con poca energía", "id_dimension_pg": 2, "tipo": "likert"},
            {"codigo": "P5", "texto": "Falta de apetito o comer en exceso", "id_dimension_pg": 1, "tipo": "likert"},
            {"codigo": "P6", "texto": "Dificultad para concentrarse en lectura o trabajo", "id_dimension_pg": 1, "tipo": "likert"},
            {"codigo": "P7", "texto": "Comentario abierto: ¿Qué situación influyó más en tu ánimo esta quincena?", "id_dimension_pg": 1, "tipo": "abierta"},
        ],
    },
    {
        "tipo_documento": "plantilla",
        "id_instrumento_pg": 2,
        "codigo": "GAD-7",
        "nombre": "GAD-7 (Ansiedad)",
        "version": "v1.0",
        "descripcion": "Escala simulada de ansiedad generalizada con subescalas cognitiva y somática.",
        "escala": {
            "min": 0,
            "max": 3,
            "etiquetas": ["0 - Nunca", "1 - Varios días", "2 - Más de la mitad de los días", "3 - Casi todos los días"],
        },
        "umbrales": {"leve": 5, "moderado": 10, "alerta_clinica": 15},
        "preguntas": [
            {"codigo": "G1", "texto": "Sentirse nervioso(a), ansioso(a) o con los nervios de punta", "id_dimension_pg": 4, "tipo": "likert"},
            {"codigo": "G2", "texto": "No poder dejar de preocuparse o controlar la preocupación", "id_dimension_pg": 4, "tipo": "likert"},
            {"codigo": "G3", "texto": "Preocuparse demasiado por diferentes cosas", "id_dimension_pg": 4, "tipo": "likert"},
            {"codigo": "G4", "texto": "Dificultad para relajarse físicamente", "id_dimension_pg": 5, "tipo": "likert"},
            {"codigo": "G5", "texto": "Estar tan inquieto(a) que es difícil permanecer sentado(a)", "id_dimension_pg": 5, "tipo": "likert"},
            {"codigo": "G6", "texto": "Comentario abierto: Describe los principales detonantes de ansiedad recientes", "id_dimension_pg": 4, "tipo": "abierta"},
        ],
    },
    {
        "tipo_documento": "plantilla",
        "id_instrumento_pg": 3,
        "codigo": "PSS-10",
        "nombre": "PSS-10 (Estrés Percibido)",
        "version": "v1.0",
        "descripcion": "Evaluación simulada de sobrecarga emocional y afrontamiento percibido.",
        "escala": {
            "min": 0,
            "max": 4,
            "etiquetas": ["0 - Nunca", "1 - Casi nunca", "2 - De vez en cuando", "3 - A menudo", "4 - Muy a menudo"],
        },
        "umbrales": {"leve": 10, "moderado": 15, "alerta_clinica": 15},
        "preguntas": [
            {"codigo": "S1", "texto": "Afectación por situaciones inesperadas durante la semana", "id_dimension_pg": 6, "tipo": "likert"},
            {"codigo": "S2", "texto": "Sensación de no poder controlar aspectos importantes del día a día", "id_dimension_pg": 7, "tipo": "likert"},
            {"codigo": "S3", "texto": "Sensación de nerviosismo y estrés constante", "id_dimension_pg": 6, "tipo": "likert"},
            {"codigo": "S4", "texto": "Confianza para manejar problemas personales satisfactoriamente", "id_dimension_pg": 8, "tipo": "likert"},
            {"codigo": "S5", "texto": "Comentario abierto: ¿Qué estrategia te ayudó a disminuir el estrés?", "id_dimension_pg": 8, "tipo": "abierta"},
        ],
    },
    {
        "tipo_documento": "plantilla",
        "id_instrumento_pg": 4,
        "codigo": "WHO-5",
        "nombre": "WHO-5 (Bienestar)",
        "version": "v1.0",
        "descripcion": "Índice simulado de bienestar positivo, vitalidad y calidad de descanso.",
        "escala": {
            "min": 0,
            "max": 5,
            "etiquetas": ["0 - Nunca", "1 - Poco tiempo", "2 - Menos de la mitad", "3 - Más de la mitad", "4 - La mayor parte", "5 - Todo el tiempo"],
        },
        "umbrales": {"bajo": 10, "optimo": 18, "alerta_clinica": 15},
        "preguntas": [
            {"codigo": "W1", "texto": "Me he sentido alegre y de buen ánimo", "id_dimension_pg": 9, "tipo": "likert"},
            {"codigo": "W2", "texto": "Me he sentido tranquilo(a) y relajado(a)", "id_dimension_pg": 9, "tipo": "likert"},
            {"codigo": "W3", "texto": "Me he sentido activo(a) y con energía", "id_dimension_pg": 9, "tipo": "likert"},
            {"codigo": "W4", "texto": "Me he despertado sintiéndome fresco(a) y descansado(a)", "id_dimension_pg": 10, "tipo": "likert"},
            {"codigo": "W5", "texto": "Comentario abierto: ¿Qué momento positivo destacas de esta semana?", "id_dimension_pg": 9, "tipo": "abierta"},
        ],
    },
]

# 18 bitácoras emocionales longitudinales (incluye 8 para paciente 33 Carlos y 5 para paciente 29 Alma)
SEED_BITACORAS = [
    # Paciente 33 (carlos.paciente@clinica.com — Terapeuta 11 Paola) -> serie longitudinal para Highcharts
    (33, "2026-10-19", "Ansioso", 8, 4, 5.5, ["Carga laboral", "Entregas"], "Sentí presión por cerrar pendientes antes del cierre semanal.", ["Respiración 4-7-8"], "Al aplicar la pausa respiratoria bajó la tensión en hombros.", ["trabajo", "estres"]),
    (33, "2026-10-22", "Estresado", 7, 5, 6.0, ["Reuniones largas"], "Me costó desconectar al terminar el día.", ["Caminata 20 min"], "Caminar después de trabajar ayudó a despejar la mente.", ["rutina", "estres"]),
    (33, "2026-10-26", "Tranquilo", 5, 6, 7.0, ["Organización matutina"], "Dividir tareas por bloques me dio mayor sensación de control.", ["Lista de prioridades", "Respiración 4-7-8"], "Dormí mejor que la semana pasada.", ["progreso", "sueno"]),
    (33, "2026-10-30", "Ansioso", 6, 5, 6.5, ["Imprevisto familiar"], "Hubo un contratiempo menor pero logré no catastrofizar.", ["Reencuadre cognitivo"], "Pude conversar el tema con calma.", ["familia", "afrontamiento"]),
    (33, "2026-11-03", "Tranquilo", 4, 7, 7.5, ["Descanso adecuado"], "Mantuve energía constante durante toda la mañana.", ["Higiene del sueño"], "Sin despertares nocturnos.", ["sueno", "bienestar"]),
    (33, "2026-11-08", "Motivado", 3, 8, 8.0, ["Actividad física"], "Me sentí con claridad mental y disfruté el fin de semana.", ["Ejercicio", "Lectura"], "Excelente recuperación emocional.", ["bienestar", "progreso"]),
    (33, "2026-11-14", "Estresado", 5, 6, 6.5, ["Cierre de sprint"], "Subió ligeramente la tensión pero la manejé sin sobresaltos.", ["Pausas activas"], "Apliqué dos pausas de 10 minutos.", ["trabajo", "afrontamiento"]),
    (33, "2026-11-20", "Tranquilo", 3, 8, 7.5, ["Constancia terapéutica"], "Noto una mejora sostenida respecto al mes anterior.", ["Respiración 4-7-8", "Bitácora"], "Listo para revisar avances en la próxima sesión.", ["progreso", "bienestar"]),
    # Paciente 29 (Alma Solis — Terapeuta 11 Paola)
    (29, "2026-10-20", "Ansioso", 8, 4, 5.5, ["Evento grupal"], "Preocupación anticipatoria antes de asistir a una reunión.", ["Respiración diafragmática"], "Logré permanecer 40 minutos en la reunión.", ["social", "exposicion"]),
    (29, "2026-10-27", "Neutral", 6, 6, 7.0, ["Semana regular"], "Menos pensamientos anticipatorios que la semana pasada.", ["Registro de pensamientos"], "Mejor descanso.", ["progreso"]),
    (29, "2026-11-03", "Tranquilo", 5, 7, 7.5, ["Conversación con amistades"], "Me sentí escuchada y cómoda.", ["Atención plena"], "Disfruté la convivencia sin urgencia por retirarme.", ["social", "bienestar"]),
    (29, "2026-11-11", "Motivado", 4, 7, 8.0, ["Logro personal"], "Participé activamente en una presentación breve.", ["Reencuadre cognitivo"], "Orgullosa del avance logrado.", ["progreso", "exposicion"]),
    (29, "2026-11-19", "Tranquilo", 3, 8, 7.5, ["Rutina nocturna"], "Mantuve consistencia en la bitácora 4 veces esta semana.", ["Bitácora", "Higiene del sueño"], "Sensación general de estabilidad.", ["bienestar"]),
    # Otros pacientes (1, 2, 3, 4, 5) para cobertura poblacional y ETL
    (1, "2026-08-12", "Cansado", 7, 4, 5.0, ["Insomnio"], "Tardé más de una hora en dormir.", ["Desconexión digital"], "Empezando a ajustar horarios.", ["sueno"]),
    (1, "2026-09-01", "Tranquilo", 4, 7, 7.5, ["Rutina nocturna"], "Cuatro noches seguidas durmiendo a tiempo.", ["Higiene del sueño"], "Mejor estado de ánimo matutino.", ["progreso", "sueno"]),
    (2, "2026-08-14", "Triste", 7, 4, 6.0, ["Aislamiento"], "Poca iniciativa al despertar.", ["Caminata corta"], "Salir a caminar mejoró ligeramente la energía.", ["activacion"]),
    (3, "2026-08-21", "Estresado", 9, 3, 5.0, ["Exámenes finales"], "Sobrecarga por entregas simultáneas.", ["Pausas breves"], "Necesito reorganizar tiempos en sesión.", ["academico", "alerta"]),
    (5, "2026-08-25", "Triste", 8, 3, 5.5, ["Sobrecarga laboral"], "Incremento en fatiga y desánimo esta semana.", ["Mindfulness 10 min"], "Agendar revisión prioritaria con terapeuta.", ["animo", "alerta"]),
]


def conectar_pg():
    return psycopg.connect(
        host=os.environ.get("DB_HOST", "localhost"),
        port=int(os.environ.get("DB_PORT", "5432")),
        dbname=os.environ.get("DB_NAME", "BD"),
        user=os.environ.get("DB_USER", "usuario"),
        password=os.environ.get("DB_PASSWORD", ""),
        sslmode=os.environ.get("DB_SSLMODE", "prefer"),
    )


def seed_plantillas(db) -> int:
    col = db[mongo_db.COLECCION_CUESTIONARIOS]
    insertadas = 0
    for plantilla in PLANTILLAS_INSTRUMENTOS:
        existe = col.find_one(
            {"tipo_documento": "plantilla", "id_instrumento_pg": plantilla["id_instrumento_pg"]}
        )
        if not existe:
            col.insert_one(dict(plantilla))
            insertadas += 1
    return insertadas


def seed_respuestas_instrumentos(conn_pg, db) -> int:
    col = db[mongo_db.COLECCION_CUESTIONARIOS]
    insertadas = 0
    with conn_pg.cursor() as cur:
        cur.execute("CALL sp_listar_aplicaciones_seed_mongo('cursor_app_seed', NULL)")
        cur.execute("FETCH ALL FROM cursor_app_seed")
        aplicaciones = cur.fetchall()

    for id_app, id_inst, inst_nombre, id_pac, id_ter, fecha_resp, id_doc_pg in aplicaciones:
        if id_doc_pg and col.find_one({"tipo_documento": "respuesta", "id_aplicacion_pg": id_app}):
            continue

        with conn_pg.cursor() as cur:
            cur.execute("CALL sp_listar_resultados_de_aplicacion(%s, 'cursor_res_app', NULL)", (id_app,))
            cur.execute("FETCH ALL FROM cursor_res_app")
            resultados = cur.fetchall()

        dims = [
            {"id_dimension_pg": d_id, "nombre_dimension": d_nom, "puntuacion": float(punt)}
            for d_id, d_nom, punt in resultados
        ]
        max_punt = max((d["puntuacion"] for d in dims), default=0.0)
        severidad = "Elevada (Alerta)" if max_punt >= 15 else ("Moderada" if max_punt >= 10 else "Leve/Estable")

        doc_resp = {
            "tipo_documento": "respuesta",
            "id_aplicacion_pg": int(id_app),
            "id_instrumento_pg": int(id_inst),
            "instrumento_nombre": inst_nombre,
            "id_paciente_pg": int(id_pac),
            "id_terapeuta_pg": int(id_ter),
            "fecha_respuesta": fecha_resp or datetime.now(timezone.utc),
            "puntuaciones_por_dimension": dims,
            "puntuacion_maxima_dimension": max_punt,
            "nivel_severidad": severidad,
            "respuesta_abierta": (
                f"Autoreporte simulado del paciente #{id_pac} durante evaluación longitudinal {inst_nombre}. "
                "Se documentan factores cotidianos y estrategias de afrontamiento."
            ),
        }

        existente = col.find_one({"tipo_documento": "respuesta", "id_aplicacion_pg": id_app})
        if existente:
            mongo_id = str(existente["_id"])
            with conn_pg.cursor() as cur:
                cur.execute("CALL sp_vincular_documento_aplicacion(%s, %s, NULL)", (id_app, mongo_id))
            conn_pg.commit()
        else:
            mongo_id, _ = mongo_db.guardar_respuesta_instrumento_coordinada(conn_pg, id_app, doc_resp)
            if mongo_id:
                insertadas += 1

    return insertadas


def seed_bitacoras(conn_pg, db) -> int:
    col = db[mongo_db.COLECCION_BITACORAS]
    insertadas = 0
    for item in SEED_BITACORAS:
        (
            id_pac, fecha_str, animo, intensidad, energia, sueno,
            detonantes, pensamientos, estrategias, notas, etiquetas
        ) = item
        fecha_dt = datetime.fromisoformat(f"{fecha_str}T20:00:00+00:00")
        existe = col.find_one({"id_paciente_pg": id_pac, "fecha_registro": fecha_dt})
        if existe:
            # Asegurar que también exista referencia en PostgreSQL
            with conn_pg.cursor() as cur:
                cur.execute(
                    "CALL sp_registrar_referencia_bitacora(%s, %s, NULL, NULL)",
                    (id_pac, str(existe["_id"])),
                )
            conn_pg.commit()
            continue

        mongo_id, _, _ = mongo_db.guardar_bitacora_coordinada(
            conn_pg,
            id_pac,
            {
                "fecha_registro": fecha_dt,
                "estado_animo": animo,
                "intensidad": intensidad,
                "energia": energia,
                "sueno_horas": sueno,
                "detonantes": detonantes,
                "pensamientos": pensamientos,
                "estrategias_usadas": estrategias,
                "notas_libres": notas,
                "etiquetas": etiquetas,
            },
        )
        if mongo_id:
            insertadas += 1
    return insertadas


def seed_resumenes_soap_e_historial(conn_pg, db) -> tuple[int, int]:
    col_res = db[mongo_db.COLECCION_RESUMENES]
    col_hist = db[mongo_db.COLECCION_HISTORIAL]
    insertados_soap = 0
    ediciones_extra = 0

    with conn_pg.cursor() as cur:
        cur.execute("CALL sp_listar_sesiones_completadas_seed_mongo('cursor_ses_soap', NULL)")
        cur.execute("FETCH ALL FROM cursor_ses_soap")
        sesiones = cur.fetchall()[:12]

    for idx, (id_ses, id_pac, pac_nom, id_ter, ter_nom, fecha_ses, modalidad, id_doc_pg) in enumerate(sesiones, start=1):
        existente = col_res.find_one({"id_sesion_pg": id_ses})
        if existente:
            if not id_doc_pg:
                with conn_pg.cursor() as cur:
                    cur.execute(
                        "CALL sp_registrar_referencia_resumen(%s, %s, NULL, NULL)",
                        (id_ses, str(existente["_id"])),
                    )
                conn_pg.commit()
            continue

        transcripcion = (
            f"[Transcripción simulada — Sesión #{id_ses} ({modalidad}, {fecha_ses})]\n"
            f"Terapeuta ({ter_nom}): ¿Cómo te sentiste con las estrategias acordadas la semana pasada?\n"
            f"Paciente ({pac_nom}): Noté avances al aplicar los ejercicios de respiración y registrar mis "
            "pensamientos antes de dormir; todavía hubo un pico de tensión a mitad de semana, pero logré regularlo más rápido.\n"
            f"Terapeuta ({ter_nom}): Excelente progreso. Ajustaremos el objetivo de seguimiento y revisaremos la escala en la siguiente cita."
        )
        nota_soap = {
            "subjetivo": f"Paciente ({pac_nom}) refiere mayor control ante detonantes cotidianos y mejor calidad de descanso, con un pico moderado de tensión a mitad de semana.",
            "objetivo": f"Sesión en modalidad {modalidad}. Paciente orientado, colaborador, afecto congruente y cumplimiento adecuado de tareas terapéuticas.",
            "analisis": "Evolución clínica favorable con consolidación progresiva de habilidades de autorregulación emocional.",
            "plan": "Continuar registro en bitácora emocional 4 veces/semana, reforzar técnica de reencuadre cognitivo y aplicar evaluación longitudinal en la próxima sesión.",
        }
        resumen_auto = (
            f"Resumen automático simulado (Sesión #{id_ses}): Adherencia positiva al plan terapéutico, "
            "reducción gradual de tensión percibida y continuidad de seguimiento longitudinal."
        )

        mongo_id, _, _ = mongo_db.guardar_resumen_soap_coordinado(
            conn_pg=conn_pg,
            id_sesion=id_ses,
            id_paciente=id_pac,
            id_terapeuta=id_ter,
            fecha_sesion=str(fecha_ses),
            transcripcion_texto=transcripcion,
            nota_soap=nota_soap,
            resumen_automatico=resumen_auto,
            palabras_clave=["adherencia", "respiracion", "reencuadre", modalidad.lower()],
            nota_extensa_terapeuta=f"Nota clínica confidencial del terapeuta {ter_nom}: paciente muestra disposición estable al proceso.",
            editado_por_usuario_pg=1,
            motivo_cambio="Generación inicial de transcripción y Nota SOAP",
        )
        if mongo_id:
            insertados_soap += 1
            # Agregar una 2da edición en las primeras 2 sesiones para tener >= 14 registros en historial_ediciones_clinicas
            if idx <= 2 and col_hist.count_documents({"id_sesion_pg": id_ses}) < 2:
                nota_soap_v2 = dict(nota_soap)
                nota_soap_v2["plan"] += " Confirmado seguimiento de objetivos para la siguiente quincena."
                mongo_db.guardar_resumen_soap_coordinado(
                    conn_pg=conn_pg,
                    id_sesion=id_ses,
                    id_paciente=id_pac,
                    id_terapeuta=id_ter,
                    fecha_sesion=str(fecha_ses),
                    transcripcion_texto=transcripcion,
                    nota_soap=nota_soap_v2,
                    resumen_automatico=resumen_auto,
                    palabras_clave=["adherencia", "respiracion", "reencuadre", "seguimiento"],
                    nota_extensa_terapeuta="Actualización posterior a revisión de resultados psicométricos.",
                    editado_por_usuario_pg=1,
                    motivo_cambio="Refinamiento de plan terapéutico tras revisión clínica",
                )
                ediciones_extra += 1

    return insertados_soap, ediciones_extra


def main() -> int:
    ok, msg, _ = mongo_db.verificar_conexion_mongo()
    if not ok:
        print(f"[ERROR] {msg}", file=sys.stderr)
        print("Configura MONGO_URI y MONGO_DB_NAME en tu archivo .env y vuelve a ejecutar este script.", file=sys.stderr)
        return 1

    print(f"[OK] {msg}")
    mongo_db.asegurar_indices_mongo()
    db = mongo_db.obtener_bd_mongo()

    conn_pg = conectar_pg()
    try:
        n_plant = seed_plantillas(db)
        n_resp = seed_respuestas_instrumentos(conn_pg, db)
        n_bit = seed_bitacoras(conn_pg, db)
        n_soap, n_ed = seed_resumenes_soap_e_historial(conn_pg, db)
    finally:
        conn_pg.close()

    _, _, conteos = mongo_db.verificar_conexion_mongo()
    print(
        f"[OK] Semilla MongoDB completada -> plantillas nuevas: {n_plant}, respuestas nuevas: {n_resp}, "
        f"bitácoras nuevas: {n_bit}, SOAP nuevos: {n_soap}, ediciones extra: {n_ed}."
    )
    print("Conteo actual por colección en MongoDB:")
    for col_name, total in conteos.items():
        print(f"  - {col_name:<30}: {total}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
