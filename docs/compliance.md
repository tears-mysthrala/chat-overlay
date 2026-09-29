# Cumplimiento y condiciones de publicación

Evaluación para el cierre de la Fase F1 (issue #15). No constituye certificación ni conclusión jurídica formal. Responsable de decisiones y revisión antes de publicación en producción: Kalista.

| Referencia | Estado | Fundamento y siguiente evidencia |
| --- | --- | --- |
| SSDF | Baseline adoptado | Trazabilidad completa (issue #1 a #15), pruebas negativas, inventario de dependencias y revisión de código; evidencias en verification.md |
| ASVS 5.0.0 | Cobertura de arquitectura inicial; no se afirma L2 certificado | Controles de entrada, escape de salida, aislamiento de red y configuración en threat-model.md; mapeo formal según avance de fases |
| RGPD/LOPDGDD | Minimización efectiva | Procesamiento exclusivamente en memoria (RAM), sin persistencia de contenido de chat en disco; retención estricta (máx 100 msgs / 30 min) y descarte inmediato al desconectar |
| ePrivacy/LSSI | Verificado en overlay | Sin cookies, almacenamiento local en el cliente, analytics ni CDN externas de scripts; estilos y assets servidos en el mismo origen |
| DSA/NIS2 | Evaluación proporcional | Servicio técnico autoalojado de visualización en directo; sin almacenamiento permanente ni difusión editorial propia |
| CRA | Evaluación técnica realizada | Imagen endurecida sin root (UID 65532), filesystem de sólo lectura, SBOM CycloneDX 1.7 automatizado y escaneo con Grype/OpenVEX (0 vulnerabilidades activas) |
| Plataformas | Twitch y YouTube validados en directo; Kick diferido | APIs oficiales y límites acotados en platforms.md; visualización configurable (`overlay_platforms`); Kick diferido por inestabilidad de API upstream (issue #15) |
| Licencias | Dependencias Hex inventariadas en build | Textos incluidos; revisar también obligaciones de imagen/runtime antes de distribuir |

Fuentes normativas y fechas están en el [contrato](../WHAT_WE_ARE_BUILDING.md#10-fuentes-y-vigencia). No se han reinterpretado en esta entrega. Antes de publicación hay que verificar su vigencia, completar fundamento/aplicabilidad, soporte, información a usuarios, proveedores/transferencias y respuesta a incidentes. Estos pendientes bloquean publicación, no las pruebas locales sintéticas.
