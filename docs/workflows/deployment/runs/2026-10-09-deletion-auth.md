# Borrado con autorización reciente — 2026-10-09

Estado actual: protección provisional en cfa1f81; no integrar. Falta el recorrido
de reautenticación verificable y aceptación integral de #48.

## Historia de 9f9bc0a — sustituida por la corrección posterior

Refs #48, #55. Base 2f268277c23dae87bd747d42c2b552c7bda70ee4.
Hallazgo: DELETE de perfil aceptaba cualquier sesión vigente hasta siete días.
Ahora exige sesión emitida en los últimos 300 s, rechaza timestamp futuro y conserva
identidad/version/revocación actuales. No se añade contraseña ni nuevos scopes;
el usuario inicia sesión de nuevo por el recorrido OAuth existente.

Control en HTTP y dentro del escritor serializado del custodio; HTTP también
transfiere el authorizer al escritor para impedir autorizar solo antes de la cola.
Error 403 explica reinicio de sesión. Demo offline directo-loopback conserva
excepción contractual, sin perfiles reales ni peers de proxy configurados.

65 pruebas focalizadas PASS seed 0: Session, HTTP/session, Custodian Operations y
ledger. Edad 0/300 válida, 301/futura denegada; A/B y anónimo denegados en producción;
custodio con sesión antigua 403 sin mutación. Ledger conserva cleanup al borrar,
cuota hasta confirmación, reintento de fallo remoto/durable y reload sin cuentas.
No se borran perfiles reales ni se contrata R2. La carga 24 h sigue running sin OOM.

Auto Review final Codex exit 0 sin hallazgos accionables. Hallazgo inicial contra
demo rechazado tras confirmar excepción explícita y límites; no afecta producción.
Suite completa y CI pendientes. Este cambio no cierra aún #48: queda conciliar
revocación/SSE/cancelación integral y evidencia de limpieza, sin fabricar borrado
remoto real. Rollback: revert de autorización/tests/docs, sin migración.

Suite completa inicial 330/331 PASS: detectó 404 local inexistente convertido 403.
Se conserva también la excepción de handle inexistente desde loopback directo,
que solo permite llegar a not_found, sin borrar datos. Auto Review posterior
exit 0 limpio. Si autorización caduca dentro de cola, la API devuelve 403 con
instrucción de iniciar sesión también en ese camino, no un error 422 genérico.

Suite completa tras corrección 331 PASS seed 0. Respuesta 403 de autorización caducada ajustada después; 56 pruebas focalizadas de la versión final PASS. Estática específica 0 findings, secrets sin fugas y diff-check PASS. CI final pendiente, sin despliegue.


## Corrección del hallazgo remoto — pendiente de aceptación

Codex detectó que created_at es emisión de sesión, no autenticación del proveedor.
Se retira la aceptación por edad: el OAuth actual no aporta una prueba verificable
reciente. El borrado de producción queda denegado incluso con sesión recién emitida;
campos de prueba suministrados al generador no habilitan el permiso. Demo offline
conserva su excepción. PR #81 no está lista para integrar; falta implementar el
recorrido de reautenticación y luego la aceptación integral #48.

La documentación Twitch describe force_verify como reautorización, no como una
prueba de contraseña o MFA: https://dev.twitch.tv/docs/authentication/getting-tokens-oidc
Google prompt=consent exige consentimiento, no autenticación reciente:
https://developers.google.com/identity/openid-connect/openid-connect
No se sustituye una evidencia por esos parámetros ni por un JWT sin verificar.
Las afirmaciones anteriores de acceso reciente quedan invalidadas por este hallazgo.

Primer intento inválido: montajes en /app cuando la imagen usa /build; sus 54 pruebas no acreditan el parche. Corregido el montaje: 57 focalizadas PASS, con aviso de cláusula inalcanzable corregido después. Validación final pendiente. Sin aceptación ni despliegue.

Versión provisional final: compilación --warnings-as-errors PASS y suite completa 332 PASS seed 0 con lib/test montados en /build. Diff-check PASS. Auto Review del nuevo delta pendiente; no es entrega lista ni cierre de #48.

Corrección editorial de espacios y separación entre estado actual e historia; sin cambios de ejecución.
