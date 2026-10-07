# OAuth local y HTTPS — Refs #42

Fuera del desarrollo directo en localhost, configurar `CHAT_PUBLIC_ORIGIN`
con el origen HTTPS del producto, sin ruta, credenciales, query ni fragmento.
Las redirecciones se construyen desde ese origen; no desde el Host recibido.
`CHAT_TRUSTED_PROXY_IPS` admite únicamente direcciones IP literales separadas
por comas. Solo esos peers pueden acreditar HTTPS mediante un único valor
`X-Forwarded-Proto: https`. El proxy debe eliminar los encabezados del cliente
antes de establecer los suyos. Para repartir la cuota anónima, debe sustituir
`X-Forwarded-For` por una única IP verificada. Solo se acepta desde un peer
configurado; valores ambiguos o inválidos comparten la cuota del propio peer.
El HTTP local no se habilita para peers declarados
como proxy ni cuando existe un origen público configurado.

Cada transacción tiene una cookie host-only independiente, HttpOnly y SameSite=Lax,
con Path=/ y Secure en HTTPS. En HTTPS usa el prefijo `__Host-`. El estado se
consume una sola vez antes del intercambio upstream. Las transacciones caducan
a los 600 segundos; hay 1024 plazas globales, hasta 512 anónimas, cuatro anónimas
por perfil y solicitante y ocho autorizadas por perfil. Reiniciar el propietario
cancela los pendientes. NAT o una dirección compartida también comparten cuota;
estos límites no constituyen protección completa frente a tráfico distribuido.

La mutación final compara el perfil con la instantánea de autorización y vuelve
a comprobar la sesión dentro del escritor serializado. Los cambios concurrentes
de identidad o autorización pueden obligar a reiniciar OAuth. Los cambios de
presentación y la renovación de ciphertext no cambian esa instantánea.
La regeneración de capabilities
invalida la instantánea anterior.

Las sesiones contienen una generación del propietario de revocaciones. Reiniciar
ese propietario invalida las sesiones emitidas anteriormente y exige nuevo login.
Solo se registran revocaciones de tokens válidos y no expirados, con su expiración.
Se conservan como máximo 4096: al alcanzar el límite se cambia la generación y se
invalida el conjunto de sesiones. La tabla permite lectura concurrente, pero solo
su propietario escribe. No constituye revocación upstream de tokens de plataforma.

Esta unidad no acredita un navegador real, proveedores reales, proxy desplegado,
CI remota ni el cierre completo de F2. Las regresiones sintéticas y la revisión
local están registradas en el workflow.
