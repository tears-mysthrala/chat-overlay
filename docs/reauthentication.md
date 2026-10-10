# Confirmación de borrado con TOTP

Refs #48. [Decisión y límites](adr/0009-sensitive-action-reauthentication.md).
El panel usa la sesión del titular y un factor previamente provisionado por el
operador. No pide ni conserva contraseñas de Twitch o Google.

## Aprovisionamiento en entorno privado

Comprueba el handle y el identificador inmutable de la cuenta vinculada, y verifica
al titular por el canal de administración existente. Una petición procedente
solo de una sesión del panel no autoriza registrar o reemplazar el factor.
Usa el artefacto revisado, un terminal privado y un directorio nuevo en almacenamiento
cifrado. En Linux se crean directorio 0700 y archivos 0600. En Windows configura
una ACL exclusiva del operador antes de generar secretos.

```sh
MIX_ENV=prod mix run --no-start scripts/provision_totp.exs prepare /private/alice alice twitch USER_ID
```

Abre `/private/alice/enrollment.txt` localmente e importa la URI en la aplicación
de autenticación del titular. No la copies a chats, logs, issues ni servicios QR.
Confirma el código mostrado, por stdin, sin incluirlo en argumentos o historial:

```sh
MIX_ENV=prod mix run --no-start scripts/provision_totp.exs confirm /private/alice
```

Solo entonces aparece `credentials.json`; se retiran los archivos provisionales.
Para varios perfiles, el operador combina las entradas confirmadas en un array
JSON de un máximo de diez. Cada handle debe aparecer una sola vez. El archivo
contiene handle, provider, user_id y secret Base32; es un secreto, no un backup público.

Monta el archivo de solo lectura en el custodio (UID 65532, acceso exclusivo) y
configura `CHAT_REAUTH_TOTP_FILE=/run/secrets/reauth-totp.json`. No lo montes en el
frontend: ese rol rechaza la variable. Reinicia el custodio para cargar cambios;
se invalidan las sesiones por el comportamiento de epoch existente. Espera el
siguiente intervalo TOTP e inicia sesión para probar. No hace falta red para verificar.

## Borrado y recuperación

En el panel, pulsa Eliminar, confirma el perfil e introduce el código actual.
Si se cancela el diálogo no se envía petición. Código erróneo, reutilizado o
caducado devuelve 403; cinco intentos alcanzados devuelve 429. Sin semilla el
panel explica cómo solicitar su configuración. Tras una escritura fallida se
conserva el perfil y se requiere un código nuevo para reintentar.

La pérdida del autenticador requiere una nueva comprobación de identidad por el
operador, provisión y sustitución del archivo privado; la sesión del panel no
permite ese reemplazo. Retira la entrada tras borrar el perfil. Reutilizar un
handle exige un factor nuevo. Copias de este archivo requieren el mismo cifrado
y custodia que el resto de secretos; nunca restaurarlo sobre otra identidad.

El control presupone un único custodio activo, según el despliegue actual. TOTP
no es resistente al phishing ni protege un navegador activamente comprometido.
No se acredita que el proveedor haya pedido contraseña/MFA recientemente.
