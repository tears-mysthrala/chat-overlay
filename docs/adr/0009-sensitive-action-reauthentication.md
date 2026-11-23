# ADR 0009: segundo factor para borrar perfiles

Fecha: 2026-10-11. Refs #48 y #55. Decisión de implementación dentro de la
continuación y mejoras autorizadas por el operador; aceptación pendiente de pruebas.

Twitch force_verify y Google prompt=consent no prueban una autenticación reciente.
La edad de una sesión OAuth tampoco lo prueba. Adoptamos TOTP estándar con
NimbleTOTP 1.0.0 (Apache-2.0, Dashbit, sin dependencias runtime transitivas), fijado
en mix.lock. No implementamos el algoritmo ni solicitamos contraseñas de plataformas.
Fuentes: https://hexdocs.pm/nimble_totp/NimbleTOTP.html y
https://hex.pm/packages/nimble_totp/1.0.0.

El operador provisiona fuera del panel una semilla por perfil e identidad vinculada,
verifica un primer código y conserva un archivo privado de configuración. No hay
alta ni sustitución del factor mediante una sesión OAuth: una sesión robada no
puede registrar un factor nuevo. Frontend rechaza esa configuración. Semillas y
URI otpauth no pasan al frontend ni al RPC ni se incluyen en logs.

El creador confirma la eliminación con sesión válida y el código actual. El
custodio comprueba sesión/identidad/version/revocación y consume el código dentro
de la mutación serializada; no crea permisos de borrado reutilizables. Cinco
intentos por perfil cada cinco minutos, un uso por intervalo de 30 segundos.
Tras iniciar el verificador, se espera al intervalo siguiente para impedir replay
tras pérdida de estado. No se acepta el intervalo anterior. No se consulta red.
Un fallo de persistencia conserva el perfil pero consume el código: reintentar
con el código del intervalo siguiente. En despliegue multiproceso haría falta
coordinar estado; el contrato actual usa un único custodio/escritor.

Sin factor provisionado se deniega el borrado y se indica contactar al operador.
La demo offline directa conserva la excepción contractual. El operador retira
la semilla después del borrado, y cualquier reutilización del handle requiere
nueva provisión. Este recorrido no declara MFA verificada por Twitch/Google.

Pruebas: positivo con código y sesión, ausencia/código erróneo/vencido/futuro,
SSO nuevo sin código, A/B, límite, replay/concurrencia, reinicio, revocación en
cola, fallos de escritura y recorrido real HTTP/RPC/UI con datos sintéticos.
Rollback: revert, sin migración de datos existentes; retirar montaje privado.
