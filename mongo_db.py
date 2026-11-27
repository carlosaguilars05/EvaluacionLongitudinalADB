"""
Módulo de conexión y coordinación documental con MongoDB (MongoDB Atlas GCP / Local).
Sistema de Gestión Clínica (Equipo 01) — Regla R5 (Arquitectura Híbrida PG + MongoDB).

Colecciones clínicas flexibles administradas:
  1. cuestionarios_instrumentos  -> plantillas dinámicas y respuestas de instrumentos psicométricos
  2. bitacoras_emocionales       -> registros emocionales longitudinales del paciente
  3. resumenes_sesion_soap       -> transcripciones, notas SOAP y resúmenes automáticos simulados
  4. historial_ediciones_clinicas -> trazabilidad de versiones y notas clínicas extensas del terapeuta

Importante: Toda operación sobre PostgreSQL dentro de este módulo respeta R1
(exclusivamente vía CALL a Stored Procedures).
"""

from __future__ import annotations

from datetime import datetime, timezone
import os
from typing import Any, Dict, List, Optional, Tuple

from bson import ObjectId
import certifi
from dotenv import load_dotenv
from pymongo import ASCENDING, DESCENDING, MongoClient
from pymongo.database import Database

load_dotenv()

COLECCION_CUESTIONARIOS = "cuestionarios_instrumentos"
COLECCION_BITACORAS = "bitacoras_emocionales"
COLECCION_RESUMENES = "resumenes_sesion_soap"
COLECCION_HISTORIAL = "historial_ediciones_clinicas"

COLECCIONES_REQUERIDAS = (
    COLECCION_CUESTIONARIOS,
    COLECCION_BITACORAS,
    COLECCION_RESUMENES,
    COLECCION_HISTORIAL,
)

_cliente_mongo: Optional[MongoClient] = None


def obtener_cliente_mongo() -> MongoClient:
    """Devuelve un cliente MongoDB reutilizable configurado desde variables de entorno."""
    global _cliente_mongo
    if _cliente_mongo is None:
        uri = os.environ.get("MONGO_URI", "mongodb://localhost:27017")
        kwargs: Dict[str, Any] = {
            "serverSelectionTimeoutMS": 5000,
            "connectTimeoutMS": 5000,
        }
        if uri.startswith("mongodb+srv://") or "tls=true" in uri.lower() or "ssl=true" in uri.lower():
            kwargs["tlsCAFile"] = certifi.where()
        _cliente_mongo = MongoClient(uri, **kwargs)
    return _cliente_mongo


def reiniciar_cliente_mongo() -> None:
    """Cierra y limpia el cliente cacheado (útil si cambia MONGO_URI en pruebas o recarga)."""
    global _cliente_mongo
    if _cliente_mongo is not None:
        _cliente_mongo.close()
        _cliente_mongo = None


def obtener_bd_mongo() -> Database:
    """Obtiene la instancia de base de datos documental configurada en MONGO_DB_NAME."""
    db_name = os.environ.get("MONGO_DB_NAME", "clinica_salud_mental")
    return obtener_cliente_mongo()[db_name]


def asegurar_indices_mongo() -> None:
    """Crea índices óptimos e idempotentes sobre las 4 colecciones clínicas."""
    db = obtener_bd_mongo()
    db[COLECCION_CUESTIONARIOS].create_index(
        [("tipo_documento", ASCENDING), ("id_instrumento_pg", ASCENDING)]
    )
    db[COLECCION_CUESTIONARIOS].create_index([("id_aplicacion_pg", ASCENDING)])
    db[COLECCION_CUESTIONARIOS].create_index(
        [("id_paciente_pg", ASCENDING), ("fecha_respuesta", DESCENDING)]
    )

    db[COLECCION_BITACORAS].create_index(
        [("id_paciente_pg", ASCENDING), ("fecha_registro", DESCENDING)]
    )

    db[COLECCION_RESUMENES].create_index(
        [("id_sesion_pg", ASCENDING)], unique=True
    )
    db[COLECCION_RESUMENES].create_index(
        [("id_terapeuta_pg", ASCENDING), ("fecha_sesion", DESCENDING)]
    )
    db[COLECCION_RESUMENES].create_index(
        [("id_paciente_pg", ASCENDING), ("fecha_sesion", DESCENDING)]
    )

    db[COLECCION_HISTORIAL].create_index(
        [("id_documento_origen", ASCENDING), ("version", DESCENDING)]
    )
    db[COLECCION_HISTORIAL].create_index([("id_sesion_pg", ASCENDING)])


def verificar_conexion_mongo() -> Tuple[bool, str, Dict[str, int]]:
    """Comprueba la conectividad real con MongoDB mediante comando ping y cuenta documentos."""
    try:
        db = obtener_bd_mongo()
        db.command("ping")
        conteos = {col: db[col].count_documents({}) for col in COLECCIONES_REQUERIDAS}
        return True, f"Conexión verificada con MongoDB ({db.name}).", conteos
    except Exception as exc:
        return False, f"No se pudo conectar a MongoDB: {exc}", {}


# ==============================================================================
# Operaciones Coordinadas PostgreSQL <-> MongoDB (con compensación ante error)
# ==============================================================================
def guardar_bitacora_coordinada(
    conn_pg: Any,
    id_paciente: int,
    datos_bitacora: Dict[str, Any],
) -> Tuple[Optional[str], Optional[int], str]:
    """
    Inserta una entrada emocional en MongoDB (`bitacoras_emocionales`) y registra
    su referencia (`id_documento_mongo`) en PostgreSQL vía `sp_registrar_referencia_bitacora`.
    Si falla PostgreSQL, compensa eliminando el documento recién creado en MongoDB.
    """
    db = obtener_bd_mongo()
    doc = {
        "id_paciente_pg": int(id_paciente),
        "fecha_registro": datos_bitacora.get("fecha_registro") or datetime.now(timezone.utc),
        "estado_animo": datos_bitacora.get("estado_animo", "Neutral"),
        "intensidad": int(datos_bitacora.get("intensidad", 5)),
        "energia": int(datos_bitacora.get("energia", 5)),
        "sueno_horas": float(datos_bitacora.get("sueno_horas", 7.0)),
        "detonantes": list(datos_bitacora.get("detonantes") or []),
        "pensamientos": (datos_bitacora.get("pensamientos") or "").strip(),
        "estrategias_usadas": list(datos_bitacora.get("estrategias_usadas") or []),
        "notas_libres": (datos_bitacora.get("notas_libres") or "").strip(),
        "etiquetas": list(datos_bitacora.get("etiquetas") or []),
    }

    res_insert = db[COLECCION_BITACORAS].insert_one(doc)
    mongo_id = str(res_insert.inserted_id)

    try:
        with conn_pg.cursor() as cur:
            cur.execute(
                "CALL sp_registrar_referencia_bitacora(%s, %s, NULL, NULL)",
                (int(id_paciente), mongo_id),
            )
            id_ref, msg = cur.fetchone()
        if id_ref is None:
            conn_pg.rollback()
            db[COLECCION_BITACORAS].delete_one({"_id": res_insert.inserted_id})
            return None, None, msg or "Error al registrar referencia en PostgreSQL; documento compensado."
        conn_pg.commit()
        return mongo_id, id_ref, msg
    except Exception as exc:
        conn_pg.rollback()
        db[COLECCION_BITACORAS].delete_one({"_id": res_insert.inserted_id})
        return None, None, f"Fallo coordinado PG-MongoDB (compensado): {exc}"


def guardar_resumen_soap_coordinado(
    conn_pg: Any,
    id_sesion: int,
    id_paciente: int,
    id_terapeuta: int,
    fecha_sesion: str,
    transcripcion_texto: str,
    nota_soap: Dict[str, str],
    resumen_automatico: str,
    palabras_clave: Optional[List[str]] = None,
    nota_extensa_terapeuta: str = "",
    editado_por_usuario_pg: Optional[int] = None,
    motivo_cambio: str = "Registro inicial de consulta",
) -> Tuple[Optional[str], Optional[int], str]:
    """
    Crea o actualiza un documento en `resumenes_sesion_soap`, registra la versión
    en `historial_ediciones_clinicas` y coordina `referencia_resumen` en PostgreSQL
    vía `sp_registrar_referencia_resumen` (con compensación en caso de fallo).
    """
    db = obtener_bd_mongo()
    ahora = datetime.now(timezone.utc)
    existente = db[COLECCION_RESUMENES].find_one({"id_sesion_pg": int(id_sesion)})

    if existente:
        nueva_version = int(existente.get("version_actual", 1)) + 1
        snapshot_previo = {
            "nota_soap": existente.get("nota_soap"),
            "resumen_automatico_simulado": existente.get("resumen_automatico_simulado"),
            "version": existente.get("version_actual", 1),
        }
        mongo_oid = existente["_id"]
        mongo_id = str(mongo_oid)

        db[COLECCION_RESUMENES].update_one(
            {"_id": mongo_oid},
            {
                "$set": {
                    "transcripcion_texto": transcripcion_texto,
                    "nota_soap": nota_soap,
                    "resumen_automatico_simulado": resumen_automatico,
                    "palabras_clave": list(palabras_clave or []),
                    "version_actual": nueva_version,
                    "actualizado_en": ahora,
                }
            },
        )
        fue_nuevo = False
    else:
        nueva_version = 1
        snapshot_previo = None
        doc_nuevo = {
            "id_sesion_pg": int(id_sesion),
            "id_paciente_pg": int(id_paciente),
            "id_terapeuta_pg": int(id_terapeuta),
            "fecha_sesion": str(fecha_sesion),
            "transcripcion_texto": transcripcion_texto,
            "nota_soap": nota_soap,
            "resumen_automatico_simulado": resumen_automatico,
            "palabras_clave": list(palabras_clave or []),
            "version_actual": nueva_version,
            "creado_en": ahora,
            "actualizado_en": ahora,
        }
        res_ins = db[COLECCION_RESUMENES].insert_one(doc_nuevo)
        mongo_oid = res_ins.inserted_id
        mongo_id = str(mongo_oid)
        fue_nuevo = True

    hist_doc = {
        "id_documento_origen": mongo_id,
        "coleccion_origen": COLECCION_RESUMENES,
        "id_sesion_pg": int(id_sesion),
        "id_paciente_pg": int(id_paciente),
        "id_terapeuta_pg": int(id_terapeuta),
        "version": nueva_version,
        "tipo_evento": "CREACION" if fue_nuevo else "EDICION",
        "nota_extensa_terapeuta": nota_extensa_terapeuta,
        "snapshot_anterior": snapshot_previo,
        "motivo_cambio": motivo_cambio,
        "editado_por_usuario_pg": editado_por_usuario_pg,
        "fecha_edicion": ahora,
    }
    res_hist = db[COLECCION_HISTORIAL].insert_one(hist_doc)

    try:
        with conn_pg.cursor() as cur:
            cur.execute(
                "CALL sp_registrar_referencia_resumen(%s, %s, NULL, NULL)",
                (int(id_sesion), mongo_id),
            )
            id_ref, msg = cur.fetchone()
        if id_ref is None:
            conn_pg.rollback()
            db[COLECCION_HISTORIAL].delete_one({"_id": res_hist.inserted_id})
            if fue_nuevo:
                db[COLECCION_RESUMENES].delete_one({"_id": mongo_oid})
            return None, None, msg or "Error al registrar referencia de resumen; compensado."
        conn_pg.commit()
        return mongo_id, id_ref, msg
    except Exception as exc:
        conn_pg.rollback()
        db[COLECCION_HISTORIAL].delete_one({"_id": res_hist.inserted_id})
        if fue_nuevo:
            db[COLECCION_RESUMENES].delete_one({"_id": mongo_oid})
        return None, None, f"Fallo coordinado SOAP PG-MongoDB (compensado): {exc}"


def guardar_respuesta_instrumento_coordinada(
    conn_pg: Any,
    id_aplicacion: int,
    doc_respuesta: Dict[str, Any],
) -> Tuple[Optional[str], str]:
    """
    Guarda la respuesta completa del instrumento en `cuestionarios_instrumentos`
    y vincula `id_documento_mongo` en PostgreSQL vía `sp_vincular_documento_aplicacion`.
    """
    db = obtener_bd_mongo()
    payload = dict(doc_respuesta)
    payload["tipo_documento"] = "respuesta"
    payload["id_aplicacion_pg"] = int(id_aplicacion)
    payload.setdefault("fecha_respuesta", datetime.now(timezone.utc))

    res_ins = db[COLECCION_CUESTIONARIOS].insert_one(payload)
    mongo_id = str(res_ins.inserted_id)

    try:
        with conn_pg.cursor() as cur:
            cur.execute(
                "CALL sp_vincular_documento_aplicacion(%s, %s, NULL)",
                (int(id_aplicacion), mongo_id),
            )
            (msg,) = cur.fetchone()
        conn_pg.commit()
        return mongo_id, msg
    except Exception as exc:
        conn_pg.rollback()
        db[COLECCION_CUESTIONARIOS].delete_one({"_id": res_ins.inserted_id})
        return None, f"Fallo coordinado instrumento PG-MongoDB (compensado): {exc}"


# ==============================================================================
# Consultas de Lectura Documental (listas para Fase 5 y gráficas Highcharts Fase 6)
# ==============================================================================
def obtener_plantilla_instrumento(id_instrumento_pg: int) -> Optional[Dict[str, Any]]:
    db = obtener_bd_mongo()
    return db[COLECCION_CUESTIONARIOS].find_one(
        {"tipo_documento": "plantilla", "id_instrumento_pg": int(id_instrumento_pg)}
    )


def listar_bitacoras_paciente(id_paciente_pg: int, limite: int = 50) -> List[Dict[str, Any]]:
    db = obtener_bd_mongo()
    cursor = (
        db[COLECCION_BITACORAS]
        .find({"id_paciente_pg": int(id_paciente_pg)})
        .sort("fecha_registro", DESCENDING)
        .limit(limite)
    )
    resultados: List[Dict[str, Any]] = []
    for doc in cursor:
        doc["_id_str"] = str(doc["_id"])
        resultados.append(doc)
    return resultados


def obtener_serie_emocional_paciente(id_paciente_pg: int) -> Dict[str, Any]:
    """Devuelve serie temporal ordenada cronológicamente para Highcharts (Jinja2 | tojson)."""
    db = obtener_bd_mongo()
    docs = list(
        db[COLECCION_BITACORAS]
        .find({"id_paciente_pg": int(id_paciente_pg)})
        .sort("fecha_registro", ASCENDING)
    )
    fechas: List[str] = []
    intensidades: List[int] = []
    energias: List[int] = []
    sueno: List[float] = []
    conteo_emociones: Dict[str, int] = {}

    for d in docs:
        fecha = d.get("fecha_registro")
        etiqueta_fecha = fecha.strftime("%Y-%m-%d") if isinstance(fecha, datetime) else str(fecha)[:10]
        fechas.append(etiqueta_fecha)
        intensidades.append(int(d.get("intensidad", 5)))
        energias.append(int(d.get("energia", 5)))
        sueno.append(float(d.get("sueno_horas", 7.0)))
        emocion = d.get("estado_animo", "Neutral")
        conteo_emociones[emocion] = conteo_emociones.get(emocion, 0) + 1

    return {
        "fechas": fechas,
        "intensidades": intensidades,
        "energias": energias,
        "sueno_horas": sueno,
        "distribucion_emociones": [
            {"name": k, "y": v} for k, v in sorted(conteo_emociones.items(), key=lambda x: -x[1])
        ],
    }


def obtener_resumen_soap_por_sesion(id_sesion_pg: int) -> Optional[Dict[str, Any]]:
    db = obtener_bd_mongo()
    doc = db[COLECCION_RESUMENES].find_one({"id_sesion_pg": int(id_sesion_pg)})
    if doc:
        doc["_id_str"] = str(doc["_id"])
    return doc


def listar_historial_ediciones_sesion(id_sesion_pg: int) -> List[Dict[str, Any]]:
    db = obtener_bd_mongo()
    return list(
        db[COLECCION_HISTORIAL]
        .find({"id_sesion_pg": int(id_sesion_pg)})
        .sort("version", DESCENDING)
    )


def obtener_documento_por_id(coleccion: str, id_hex: str) -> Optional[Dict[str, Any]]:
    if coleccion not in COLECCIONES_REQUERIDAS or not ObjectId.is_valid(id_hex):
        return None
    db = obtener_bd_mongo()
    return db[coleccion].find_one({"_id": ObjectId(id_hex)})
