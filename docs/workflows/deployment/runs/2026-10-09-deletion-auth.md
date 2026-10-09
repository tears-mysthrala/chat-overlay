# Borrado con autorización reciente — 2026-10-09

Refs #48, #55. Base2f268277c23dae87bd747d42c2b552c7bda70ee4.
Hallazgo: DELETE de perfil aceptaba cualquier sesión vigente hasta siete días.
Ahora exige sesión emitida en los últimos300s, rechaza timestamp futuro y conserva
identidad/version/revocación actuales. No se añade contraseña ni nuevos scopes;
el usuario inicia sesión de nuevo por el recorrido OAuth existente.

Control en HTTP y dentro del escritor serializado del custodio; HTTP también
transfiere el authorizer al escritor para impedir autorizar solo antes de la cola.
Error403 explica reinicio de sesión. Demo offline directo-loopback conserva
excepción contractual, sin perfiles reales ni peers de proxy configurados.

65 pruebas focalizadas PASS seed0: Session, HTTP/session, Custodian Operations y
ledger. Edad0/300 válida,301/futura denegada; A/B y anónimo denegados en producción;
custodio con sesión antigua403 sin mutación. Ledger conserva cleanup al borrar,
cuota hasta confirmación, reintento de fallo remoto/durable y reload sin cuentas.
No se borran perfiles reales ni se contrata R2. La carga24h sigue running sin OOM.

Auto Review final Codex exit0 sin hallazgos accionables. Hallazgo inicial contra
demo rechazado tras confirmar excepción explícita y límites; no afecta producción.
Suite completa y CI pendientes. Este cambio no cierra aún #48: queda conciliar
revocación/SSE/cancelación integral y evidencia de limpieza, sin fabricar borrado
remoto real. Rollback: revert de autorización/tests/docs, sin migración.

Suite completa inicial330/331 PASS: detectó404 local inexistente convertido403.
Se conserva también la excepción de handle inexistente desde loopback directo,
que solo permite llegar a not_found, sin borrar datos. Auto Review posterior
exit0 limpio. Si autorización caduca dentro de cola, la API devuelve403 con
instrucción de iniciar sesión también en ese camino, no un error422 genérico.

Suite completa tras corrección331 PASS seed0. Respuesta403 de autorización caducada ajustada después;56 pruebas focalizadas de la versión final PASS. Estática específica0 findings, secrets sin fugas y diff-check PASS. CI final pendiente, sin despliegue.

