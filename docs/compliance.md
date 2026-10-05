# Cumplimiento y condiciones de publicación

Evaluación histórica del cierre F2 (#21), con deuda actual en #55. No acredita cierre de SEC-13/SEC-17 ni evaluación ASVS completa. No constituye certificación ni conclusión jurídica formal. Responsable de decisiones y revisión antes de publicación en producción: Kalista.

| Referencia | Estado | Fundamento y siguiente evidencia |
| --- | --- | --- |
| SSDF | Baseline adoptado | Trazabilidad histórica (issues #1 a #21); seguimiento actual en #55, pruebas negativas de seguridad, inventario de dependencias, scripts de pre-push y revisión continua de código; evidencias en verification.md |
| ASVS 5.0.0 | Cobertura parcial de controles; mapeo verificable pendiente en #42, sin certificación L2 | Capability Tokens opacos de 32 bytes con entropía criptográfica (256 bits), hashing SHA-256 en reposo y verificación en tiempo constante (`secure_compare/2`); cifrado simétrico autenticado AEAD (AES-256-GCM) nativo OTP para credenciales en reposo (SEC-15); OAuth 2.0 PKCE (S256) y firmado criptográfico HMAC-SHA256 de `state` anti-CSRF (SEC-14); controles de entrada, escape de salida y aislamiento de red en threat-model.md |
| RGPD/LOPDGDD | Minimización efectiva | Procesamiento de chats exclusivamente en memoria (RAM), sin persistencia de contenido en disco; retención estricta (máx 100 msgs / 30 min) y descarte de streams; cuotas de almacenamiento delimitadas en Cloudflare R2 con subida directa sin custodia de datos por el servidor (*Zero Server Footprint*) |
| ePrivacy/LSSI | Verificado en overlay y panel | Sin cookies de rastreo, analítica ni CDN externas de scripts; estilos y assets servidos en el mismo origen; CSP estricta con hash específico para inyección de estilos de OBS Studio sin `unsafe-inline` |
| DSA/NIS2 | Evaluación proporcional | Servicio técnico autoalojado de visualización en directo; sin almacenamiento masivo permanente ni difusión editorial propia |
| CRA | Evaluación técnica realizada | Imagen endurecida sin root (UID 65532), filesystem de sólo lectura, límites de recursos efectivos, SBOM CycloneDX 1.7 automatizado y escaneo con Grype/OpenVEX (0 vulnerabilidades activas) |
| Plataformas y OBS | Twitch, YouTube y OBS Studio validados en directo; Kick diferido | APIs oficiales y límites acotados en platforms.md; visualización configurable (`overlay_platforms`); OBS Studio 32.2.2 verificado con CSP restrictiva; Kick formalmente diferido por inestabilidad de API upstream (issue #15) |
| Licencias | Dependencias Hex inventariadas en build | Textos incluidos; revisar también obligaciones de imagen/runtime antes de distribuir |

Fuentes normativas y fechas están en el [contrato](../WHAT_WE_ARE_BUILDING.md#10-fuentes-y-vigencia). No se han reinterpretado en esta entrega. Antes de publicación hay que verificar su vigencia, completar fundamento/aplicabilidad, soporte, información a usuarios, proveedores/transferencias y respuesta a incidentes. Estos pendientes bloquean publicación, no las pruebas locales sintéticas ni la validación en OBS.
