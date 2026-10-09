# Backlog reconciliado — 08-10-2026

Refs #55. Base integrada comprobada: `640ef847d6dd76b2f3bbc7f41a902e50df3b1698`
(PR #68). El estado de un issue abierto no equivale a ausencia de implementación.
Este inventario dirigido no sustituye una auditoría completa ni acredita ASVS L2.

## Cierre del producto existente: F2

- #32: cuotas y limpieza duradera implementadas (PR #57). Revisar aceptación contra almacenamiento local actual y distinguir cobertura R2.
- #48: eliminación/revocación y saneamiento: conciliar pruebas de limpieza, fallos/reinicio y aislamiento A/B; no borrar datos reales para acreditar el gate.
- #51: persistencia PostgreSQL/RLS y aceptación conciliadas en [registro 09-10](workflows/deployment/runs/2026-10-09-persistence-acceptance.md): roles/pool/A-B/fallos/concurrencia/reinicio/export probados. Cierre pendiente de integración del registro.
- #40: recuperación cifrada y mantenimiento offline integrados (PR #66). Consolidar evidencia de restauración/rotación y procedimiento.
- #49: cuarentena y coordinador integrados (PR #65). Conciliar aceptación negativa, límites y artefacto desplegado.
- #62: almacenamiento local privado implementado y aceptación conciliada en PR #77:24 regresiones de aplicación y12 de disco/coordinador PASS, despliegue/panel/OBS referenciados. Cerrado mediante PR #77 (main32e18b2). R2/S3 no es requisito de la instalación local; cuarentena global sigue en #49.
- #64: previsualización manual integrada (PR #65); imagen y audio probados en OBS real. No acredita eventos automáticos de follows/subs.
- #47: lectores usan coordinador OAuth; queda cerrar matriz de expiración, refresh, revocación y recuperación, no desarrollar otra integración equivalente.
- #43: UI y pruebas de navegador integradas (PR #68); Twitch real, OBS, audio y revocación probados. Callback nuevo Google/YouTube posterior al corte pendiente.
- #39: separación frontend/custodio desplegada y verificada. Completar matriz operativa y seguir incompatibilidad CSP en #69.
- #42: reconciliar ASVS y regresiones con implementación/evidencia actuales; no declarar conformidad completa.
- #41: actualizar contrato, arquitectura, verificación y handoff; separar registros históricos de estado vigente.

## Validación y distribución

- #34: carga sintética 4 h; analizar entrega, p95 y tendencia de recursos antes de ejecutar 24 h. PR #33 ya integrada. Sin carga contra plataformas reales.
- #44: fallos/cuotas/latencia y recuperación de conectores en candidata; separar fixtures y upstream real.
- #35: firma, procedencia y evidencia ligada al mismo artefacto.
- #36: licencias de runtime, imagen y assets antes de distribución.
- #45: condiciones vigentes de plataformas, atribución y visualización.
- #37: evaluación de aplicabilidad/privacidad y revisión humana; no es dictamen automático.
- #38: soporte, actualización e incidentes; incluir renovación de certificados mTLS, backup y restauración.
- #46: acciones CI y exigibilidad de checks/protecciones; registrar restricciones reales del repositorio.
- #50: revisar excepciones OpenVEX y actualización antes del 21-10-2026.
- #69: identificar y corregir inyección del borde incompatible con CSP sin debilitar la política.
- #70: reproducir y resolver aviso de deprecación xref de Postgrex.
- #4: cierre global de aceptación; permanece abierto hasta acreditar sus condiciones.

## Desarrollo y propuestas posteriores

- #63: escalado automático de originales grandes dentro del decodificador aislado; aún no implementado. Las copias reducidas offline no acreditan esta función.
- #52: definir bot/comandos/acciones y, si se decide incluirlos, eventos automáticos de alertas; alcance y permisos concretos antes de implementar.
- #53: personalización avanzada; runners únicamente si el caso de uso los necesita.
- #54: Kick continúa diferido; no se reactiva por actualizar este inventario.

## Orden de ejecución

1. Consolidar evidencia y corregir documentación obsoleta (#41/#55), cerrando tickets solo al comprobar toda su aceptación.
2. Preparar y ejecutar #34 en aislamiento; aprovechar la duración para revisar #42/#44 y preparar #35–#38/#45/#46.
3. Resolver #69/#70 y revisar #50 antes de su fecha límite. Repetir las pruebas afectadas por cambios de código/imagen.
4. Completar #63. Definir después #52; #53 depende de una necesidad concreta.

No hay nuevas funciones, cambios de producción ni cierres de issues implícitos en este documento.
