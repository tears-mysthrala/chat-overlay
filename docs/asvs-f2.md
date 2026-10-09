# ASVS 5.0.0 — selección F2 y deuda verificable (#42)

**Evaluación parcial, sin certificación ni afirmación de cumplimiento L2.** Selección
verificada el 02-10-2026 contra el repositorio oficial OWASP/ASVS, referencia `v5.0.0`
resuelta a commit `60437a5ed660f757ab9a8d9e0b7181a06492446a`. Los IDs y niveles de
esta tabla se contrastaron con esa edición; los resúmenes son propios.

Base de código: pila #56/#57/#58/#41, commit `a327295`. La batería completa de esa
candidata pasa 240 pruebas (semilla 318718); ello no implica verificar todos los
requisitos de cada fila. `Probado parcialmente` identifica regresiones relevantes,
no un PASS global del requisito. `Pendiente` es deuda conocida; `No validado` es
falta de evidencia. Las filas no seleccionadas **no se presumen cumplidas**.
Los niveles L3 incluidos aportan controles útiles, no elevan el nivel declarado.

| ID oficial (enlace a fuente fijada) | Nivel | Resumen | Estado | Evidencia local | Límite / siguiente paso |
| --- | --- | --- | --- | --- | --- |
| [3.2.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L1 | Texto sin interpretación HTML | Parcial | [app.js](../priv/static/app.js); [http_test.exs](../test/http_test.exs) | DOM/OBS actual en #43 |
| [3.3.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L1 | Cookies Secure y prefijo | Pendiente | [session.ex](../lib/chat_overlay/session.ex); [session_test.exs](../test/session_test.exs) | Revisar prefijo de cookie y TLS real; #42/#39 |
| [3.3.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | SameSite según uso | Parcial | [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Lax probado; navegador/OAuth real #43 |
| [3.3.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | Cookie limitada al host | Pendiente | [session.ex](../lib/chat_overlay/session.ex) | Prefijo __Host no acreditado; #42 |
| [3.3.4](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | Cookie HttpOnly | Probado parcialmente | [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Cabecera verificada; flujos de navegador #43 |
| [3.4.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L1 | HSTS | No validado | [operations.md](../docs/operations.md) | Proxy real fuera de la candidata; #39 |
| [3.4.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | CSP | Parcial | [http_test.exs](../test/http_test.exs); [web_f2_test.exs](../test/web_f2_test.exs) | Repetir OBS y recursos externos #43/#49 |
| [3.4.4](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | Nosniff | Parcial | [web.ex](../lib/chat_overlay/web.ex); [http_test.exs](../test/http_test.exs) | Revisar también respuestas CDN/proxy #39/#49 |
| [3.4.5](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x12-V3-Web-Frontend-Security.md) | L2 | Referrer restringido | Parcial | [web.ex](../lib/chat_overlay/web.ex) | Validación extremo a extremo #43 |
| [5.2.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L1 | Límite de archivos | Parcial | [media_test.exs](../test/media_test.exs); [web_f2_test.exs](../test/web_f2_test.exs) | HEAD y firma no prueban costo de decodificación #49 |
| [5.2.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L1 | Formato real | Pendiente | [media-storage.md](../docs/media-storage.md) | Cuarentena y decoder #49 |
| [5.2.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L2 | Descompresión acotada | No aplicable al flujo actual | [media.ex](../lib/chat_overlay/media.ex) | No acepta archivos comprimidos; reevaluar si se amplía entrada |
| [5.2.4](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L3 | Cuota y número de objetos | Parcial | [media_ledger_test.exs](../test/media_ledger_test.exs) | Inventario 128 global; conciliación heredada y PUT reutilizable #48/#49 |
| [5.2.6](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L3 | Dimensiones de imagen | Pendiente | [0005-f2-isolation-and-quarantine-proposal.md](../docs/adr/0005-f2-isolation-and-quarantine-proposal.md) | Propuesta sin aprobar; #49 |
| [5.3.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L1 | Claves y rutas de archivo | Probado parcialmente | [media_ledger_test.exs](../test/media_ledger_test.exs); [media_test.exs](../test/media_test.exs) | Claves por perfil y disco Linux real probados en [aceptación local #62](workflows/deployment/runs/2026-10-09-local-media-acceptance.md); R2 no validado en vivo y aceptación global de cuarentena #49 pendiente |
| [5.4.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x14-V5-File-Handling.md) | L2 | Análisis antimalware | Pendiente | [media-storage.md](../docs/media-storage.md) | No implementado; decisión de alcance/compensación en #49, no marcar N/A |
| [7.1.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L2 | Política de duración | Pendiente | [session.ex](../lib/chat_overlay/session.ex) | TTL existente no sustituye política de riesgo/idle; #42 |
| [7.2.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L1 | Verificación backend | Probado parcialmente | [session_test.exs](../test/session_test.exs); [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Revisión externa/flujo completo pendiente |
| [7.3.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L2 | Inactividad | Pendiente | [session.ex](../lib/chat_overlay/session.ex) | No se acredita timeout de inactividad; #42 |
| [7.3.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L2 | Caducidad absoluta | Parcial | [session_test.exs](../test/session_test.exs) | Expiración probada; justificar duración por riesgo #42 |
| [7.4.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L1 | Logout y caducidad | Parcial | [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Revocación probada en proceso; persistencia/reinicio requiere evaluación #42 |
| [7.4.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L1 | Baja de cuenta | Parcial | [session_test.exs](../test/session_test.exs); [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Unlink/relink y borrado probados; flujo integral #48 |
| [7.5.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x16-V7-Session-Management.md) | L2 | Reautenticar cambios sensibles | Pendiente | [media-storage.md](../docs/media-storage.md) | Paso adicional de reautenticación #48/#42 |
| [8.2.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L1 | Autorización por función | Probado parcialmente | [web_session_auth_test.exs](../test/web_session_auth_test.exs) | No equivale a examen de todas las rutas |
| [8.2.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L1 | Autorización por objeto | Probado parcialmente | [web_session_auth_test.exs](../test/web_session_auth_test.exs); [web_f2_test.exs](../test/web_f2_test.exs) | Casos A/B y enlaces; completar matriz de rutas #42 |
| [8.2.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L2 | Autorización por campo | Parcial | [web_f2_test.exs](../test/web_f2_test.exs) | can_upload y asociación; revisar otros campos #42 |
| [8.3.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L1 | Decisiones en servidor | Probado parcialmente | [web_session_auth_test.exs](../test/web_session_auth_test.exs); [media_ledger_test.exs](../test/media_ledger_test.exs) | UI no es frontera; revisar nuevas rutas siempre |
| [8.3.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L3 | Revocación inmediata | Parcial | [token_lifecycle_gate_test.exs](../test/token_lifecycle_gate_test.exs); [web_f2_test.exs](../test/web_f2_test.exs) | Carreras cubiertas; no se acredita toda infraestructura |
| [8.4.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x17-V8-Authorization.md) | L2 | Aislamiento entre usuarios | Parcial | [session_test.exs](../test/session_test.exs); [0004-f2-profile-persistence.md](../docs/adr/0004-f2-profile-persistence.md) | PostgreSQL/RLS con rol/pool/producto probados en [aceptación #51](workflows/deployment/runs/2026-10-09-persistence-acceptance.md); no acredita todo8.4.1 ni protege de aplicación totalmente comprometida |
| [10.1.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x19-V10-OAuth-and-OIDC.md) | L2 | Tokens solo en backend | Parcial | [profiles_oauth_test.exs](../test/profiles_oauth_test.exs); [web_session_auth_test.exs](../test/web_session_auth_test.exs) | Auditar serialización/logs continuamente |
| [10.1.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x19-V10-OAuth-and-OIDC.md) | L2 | Flujo OAuth ligado al navegador | Probado parcialmente | [oauth_flow_test.exs](../test/oauth_flow_test.exs); [web_session_auth_test.exs](../test/web_session_auth_test.exs); [web_oauth_test.exs](../test/web_oauth_test.exs) | Cookie HttpOnly y consumo atómico antes de upstream; cross-browser/replay/concurrencia/reinicio sintéticos. Navegador/proveedor real pendientes #42/#43/#44 |
| [10.2.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x19-V10-OAuth-and-OIDC.md) | L2 | Protección CSRF OAuth | Parcial | [oauth_test.exs](../test/oauth_test.exs); [web_oauth_test.exs](../test/web_oauth_test.exs) | State/PKCE sintéticos; proveedor real #44 |
| [10.2.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x19-V10-OAuth-and-OIDC.md) | L2 | Separación de proveedores | No validado | [oauth.ex](../lib/chat_overlay/oauth.ex); [web.ex](../lib/chat_overlay/web.ex) | Auditar mix-up explícitamente #42 |
| [11.1.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x20-V11-Cryptography.md) | L2 | Ciclo de vida de claves | Parcial | [recovery.md](../docs/recovery.md); [recovery_test.exs](../test/recovery_test.exs) | No política organizativa NIST completa; aprobación humana |
| [11.2.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x20-V11-Cryptography.md) | L2 | Cambio de claves y algoritmos | Parcial | [recovery_test.exs](../test/recovery_test.exs) | Rotación offline probada; agilidad general no acreditada |
| [11.3.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x20-V11-Cryptography.md) | L2 | Integridad del cifrado | Probado parcialmente | [crypto_test.exs](../test/crypto_test.exs); [recovery_test.exs](../test/recovery_test.exs) | AEAD/AAD con casos negativos; sin certificación criptográfica |
| [11.4.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x20-V11-Cryptography.md) | L2 | Hash de contraseñas | No aplicable al flujo actual | [session.ex](../lib/chat_overlay/session.ex) | No almacena contraseñas locales; SHA de capabilities no es hash de password |
| [11.5.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x20-V11-Cryptography.md) | L2 | Aleatoriedad y entropía | Parcial | [crypto.ex](../lib/chat_overlay/crypto.ex); [crypto_test.exs](../test/crypto_test.exs) | CSPRNG OTP; test de longitud no demuestra entropía por sí solo |
| [12.3.2](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x21-V12-Secure-Communication.md) | L2 | TLS saliente verificado | Parcial | [net.ex](../lib/chat_overlay/net.ex) | Verificación/pinning en código; fallos de infraestructura #39/#44 |
| [14.2.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x23-V14-Data-Protection.md) | L1 | Secretos fuera de URLs | Pendiente | [operations.md](../docs/operations.md) | Capabilities OBS y firmas R2 en URL son excepción a evaluar #42/#39 |
| [14.2.7](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x23-V14-Data-Protection.md) | L3 | Retención y eliminación | Parcial | [media_ledger_test.exs](../test/media_ledger_test.exs); [media-storage.md](../docs/media-storage.md) | Borrado/retención completa #48/#37 |
| [14.3.1](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x23-V14-Data-Protection.md) | L1 | Limpiar cliente al salir | Probado parcialmente | [app.js](../priv/static/app.js) | PR #61 borra obs_token_* de sessionStorage tras logout exitoso; navegador sintético verifica limpieza, revisar otros caminos de salida #43 |
| [14.3.3](https://github.com/OWASP/ASVS/blob/60437a5ed660f757ab9a8d9e0b7181a06492446a/5.0/en/0x23-V14-Data-Protection.md) | L2 | No datos sensibles en storage cliente | Pendiente | [app.js](../priv/static/app.js) | Capability OBS guardado en sessionStorage; retirar persistencia cliente o justificar excepción #43/#42 |

## Aplicabilidad y trabajo pendiente

V6 sobre contraseñas locales no se marca como cumplido: el producto delega login al
proveedor y no implementa contraseña/MFA propios. Las secciones de servidor OAuth
10.4 y proveedor OIDC 10.6/10.7 pertenecen al proveedor externo; su exclusión de la
implementación local no garantiza comportamiento del proveedor. Los tokens propios
son AEAD, no JWT; no se trasladan automáticamente controles JWT sin analizar su función.

Los casos negativos existentes cubren A/B, identidad de callback, unlink/relink,
revocación, workers cancelados, respuesta OAuth malformada, disco fallido y multimedia
falseada. No se añaden tests que solo repitan la implementación para inflar conteos.
La carrera de notificación de Registry detectada al ejecutar el gate se corrigió en
`a327295`: se exige DOWN de ambos procesos y baja acotada del registro, sin exclusiones.

Esta entrega no cierra #42: quedan política de sesiones, cobertura exhaustiva de rutas,
revisión de cookies/almacenamiento cliente, mix-up, excepciones de secretos en URL y
revisión humana del riesgo residual. Los hallazgos reproducibles sensibles siguen el
canal privado DEV-09; aquí se registran únicamente controles y metadatos de seguimiento.
Los gates #39/#43/#48/#49/#51 no se satisfacen sustituyéndolos por esta matriz.

## Procedencia

Archivos consultados mediante la API oficial de GitHub, con digest SHA-256 local:

- `0x12-V3-Web-Frontend-Security.md`: `02de197d5aa55592cfa524e66d4aa15bd3e8955e23e76438ac413c94172488fc`
- `0x14-V5-File-Handling.md`: `079a51123e5156a5ffc6329f266d49752cb60f6b780899484c3f1cfde3734ebb`
- `0x16-V7-Session-Management.md`: `4aec329f2642ae750fbe1abac5da7e8a7bcfec6fc331bb0a46916970f9c88236`
- `0x17-V8-Authorization.md`: `60c188b1703cab2086841d8f1b4adc0ededf66ed38c676a11bb92347646b5330`
- `0x19-V10-OAuth-and-OIDC.md`: `2da443986ba40987bd0908bbd7da2372ab0d777701cc590f4eb0fdad6ae804ed`
- `0x20-V11-Cryptography.md`: `a64f3f2dc6f53565dfba66e40fd336b50eab6cdb530c2791f62db8b58202bacf`
- `0x21-V12-Secure-Communication.md`: `62f7737e74172d3d2177bd838c1bc44461d0a70c37cfd09d9e4669252b480775`
- `0x23-V14-Data-Protection.md`: `a9ba33b7c77379fed0f27fd019945e10fa143c63b8c4e4783b7cf587c9f56039`
