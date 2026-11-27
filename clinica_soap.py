"""
Generador automático simulado de Notas SOAP y resúmenes clínicos a partir de
la transcripción de una sesión terapéutica (sin dependencias externas ni APIs).
Sistema de Gestión Clínica (Equipo 01) — Fase 5.

Aviso: Este módulo es una simulación académica de apoyo a la documentación
clínica y NO constituye diagnóstico médico ni sustituye el criterio profesional.
"""

from __future__ import annotations

import re
from typing import Dict, List, Tuple

PALABRAS_RIESGO = {
    "ansiedad", "estres", "estrés", "insomnio", "tristeza", "agotamiento",
    "sobrecarga", "rumiacion", "rumiación", "preocupacion", "preocupación",
    "miedo", "cansancio", "bloqueo", "tension", "tensión", "desanimo", "desánimo",
}

PALABRAS_PROGRESO = {
    "avance", "mejora", "mejoría", "calma", "respiracion", "respiración",
    "tranquilo", "tranquila", "logro", "bitacora", "bitácora", "mindfulness",
    "descanso", "constancia", "reencuadre", "ejercicio", "caminata", "limites", "límites",
}


def extraer_palabras_clave(texto: str) -> Tuple[List[str], List[str], List[str]]:
    """Extrae palabras clave de riesgo, progreso y combinadas a partir del texto."""
    tokens = set(re.findall(r"[a-záéíóúñü]+", texto.lower()))
    riesgo = sorted(tokens & PALABRAS_RIESGO)
    progreso = sorted(tokens & PALABRAS_PROGRESO)
    combinadas = sorted(set(riesgo + progreso))[:8]
    return riesgo, progreso, combinadas


def generar_nota_soap_simulada(
    transcripcion: str,
    nombre_paciente: str,
    modalidad: str,
    fecha_sesion: str,
) -> Dict[str, object]:
    """
    Genera una Nota SOAP estructurada (Subjetivo, Objetivo, Análisis, Plan) y
    un resumen automático simulado a partir de la transcripción proporcionada.
    """
    texto_limpio = (transcripcion or "").strip()
    if not texto_limpio:
        texto_limpio = (
            f"Sesión terapéutica con {nombre_paciente} en modalidad {modalidad}. "
            "Se revisaron avances generales y seguimiento de objetivos del plan."
        )

    lineas = [ln.strip() for ln in texto_limpio.splitlines() if ln.strip()]
    intervenciones_paciente = [
        re.sub(r"^paciente[^:]*:\s*", "", ln, flags=re.IGNORECASE)
        for ln in lineas
        if re.match(r"^paciente\b", ln, flags=re.IGNORECASE)
    ]

    riesgo, progreso, palabras_clave = extraer_palabras_clave(texto_limpio)

    # S - Subjetivo
    if intervenciones_paciente:
        extracto_pac = " ".join(intervenciones_paciente)[:420]
        subjetivo = f"{nombre_paciente} refiere durante la sesión: \"{extracto_pac}\""
    else:
        extracto = texto_limpio[:360]
        subjetivo = f"Durante la sesión, {nombre_paciente} comenta: {extracto}"

    # O - Objetivo
    temas_obs = ", ".join(palabras_clave) if palabras_clave else "seguimiento general del proceso"
    objetivo = (
        f"Sesión realizada el {fecha_sesion} en modalidad {modalidad}. "
        f"Participación activa y diálogo estructurado ({len(lineas)} segmento(s) transcritos). "
        f"Ejes temáticos identificados en el discurso: {temas_obs}."
    )

    # A - Análisis
    if progreso and riesgo:
        analisis = (
            f"Se observa evolución clínica con recursos de afrontamiento activos ({', '.join(progreso[:4])}), "
            f"coexistiendo con factores de tensión que requieren monitoreo ({', '.join(riesgo[:4])})."
        )
    elif progreso:
        analisis = (
            f"Evolución clínica favorable: se refuerzan indicadores de progreso y autorregulación "
            f"({', '.join(progreso[:5])})."
        )
    elif riesgo:
        analisis = (
            f"Presencia de indicadores sintomáticos relevantes ({', '.join(riesgo[:5])}) que ameritan "
            "seguimiento cercano, revisión de escalas psicométricas y ajuste de estrategias."
        )
    else:
        analisis = (
            "Sesión de seguimiento estable; el paciente mantiene continuidad con el encuadre terapéutico."
        )

    # P - Plan
    recomendaciones = [
        "Continuar el registro periódico en la bitácora emocional para seguimiento longitudinal.",
    ]
    if riesgo:
        recomendaciones.append(
            f"Reforzar técnicas de regulación enfocadas en {', '.join(riesgo[:3])} y evaluar aplicación de instrumento psicométrico."
        )
    if progreso:
        recomendaciones.append(
            f"Consolidar hábitos protectores reportados ({', '.join(progreso[:3])}) y actualizar avance de objetivos del plan."
        )
    recomendaciones.append("Revisar cumplimiento de acuerdos en la siguiente sesión programada.")
    plan = " ".join(recomendaciones)

    # Resumen automático simulado
    tendencia = (
        "progreso con focos de atención" if (progreso and riesgo)
        else ("evolución favorable" if progreso else ("requiere monitoreo sintomático" if riesgo else "seguimiento estable"))
    )
    resumen_automatico = (
        f"Resumen automático simulado ({fecha_sesion}, {modalidad}) — {nombre_paciente}: "
        f"Tendencia detectada: {tendencia}. "
        f"Conceptos clave: {', '.join(palabras_clave) if palabras_clave else 'continuidad terapéutica'}. "
        "Nota generada como apoyo documental; sujeta a validación del terapeuta."
    )

    return {
        "nota_soap": {
            "subjetivo": subjetivo,
            "objetivo": objetivo,
            "analisis": analisis,
            "plan": plan,
        },
        "resumen_automatico": resumen_automatico,
        "palabras_clave": palabras_clave or ["seguimiento", modalidad.lower()],
    }
