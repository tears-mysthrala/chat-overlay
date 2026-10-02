# Navegador/OBS — candidata #43

Ensayo local 02-10-2026 sobre base `0fcf001` más los cambios de #43: permisos de
subida visibles y limpieza de capabilities en logout. Solo perfiles Alice/Bob y
OAuth sintéticos, sin cuentas reales ni tráfico a Twitch/YouTube/R2.

## Reproducir navegador

```sh
MIX_ENV=test mix run --no-start --no-halt scripts/browser_fixture.exs /ruta/privada/nueva
```

El directorio debe ser nuevo; escucha solo en `127.0.0.1:4143`. El fixture instala
clientes OAuth falsos antes de arrancar fuentes demo. No usar `MIX_ENV=prod`, ni
configuración/credenciales reales; el script rechaza otros entornos.

En el preview nativo T3, abrir `http://localhost:4143`. Evaluar la función de
`scripts/browser_checks.js` con argumento `login`, recargar, evaluar `verify`,
pulsar Cerrar sesión y evaluar `logged-out`. No imprime cookies, capabilities ni
URLs firmadas. La confirmación de regeneración se acepta programáticamente solo
durante el test; no prueba interacción manual con el diálogo nativo.

Resultado observado: Chrome 152.0.7977.130 / Electron 44.4.2 (T3 Code 0.0.44),
1280x800 y 390x844, todas las comprobaciones de `verify` pasan:

- Login por callback sintético, cookie no accesible a JavaScript y selector solo Alice.
- Escritura sobre Bob rechazada con 403.
- Controles de subir deshabilitados y explicación visible cuando `can_upload=false`.
- URL HTTP inválida: error HTTPS visible y botón disponible para corregirlo.
- Enlace nuevo 200, anterior 401, ausencia de capability 401 y comienzo de SSE.
- Sin desbordamiento horizontal en ambos tamaños.
- Logout: sesión no autenticada, banner oculto y cero copias `obs_token_*` en sessionStorage.

Durante el flujo de regeneración no se capturaron eventos `error` ni violaciones CSP.
Esto no demuestra ausencia de errores antes de instalar esos listeners. El snapshot
nativo T3 falló repetidamente; navegación, evaluación y resize sí funcionaron. No hay
captura visual del navegador ni prueba manual completa de solapamientos. Las pruebas
inspeccionan DOM y dimensiones; no se atribuye evidencia visual inexistente.

## Runner CI preparado, ejecución pendiente

`source-and-tests` instala `playwright@1.63.0` como dependencia exclusiva de desarrollo
mediante `npm ci` y su lockfile; requiere Node >=20. Solo se ejecuta en PR, acción
manual o auditoría programada. No se ejecuta Playwright localmente como alternativa
al preview T3. `scripts/browser_ci.js` exige `GITHUB_ACTIONS=true` y reutiliza la
función exportada de `browser_checks.js` mediante `page.evaluate(function, stage)`,
sin evaluación de cadenas ni duplicación de las comprobaciones.

`scripts/ci_browser.sh` inicia la imagen de validación en una red Docker `--internal`,
sin volúmenes del operador, con rootfs de solo lectura, tmpfs de 64 MiB y límites
CPU/memoria/PIDs. Publica exclusivamente `127.0.0.1:4143`. El fixture sigue limitado a
MIX_ENV=test y solo escucha en todas las interfaces internas con el opt-in explícito
`BROWSER_FIXTURE_CONTAINER=1`. El trap elimina únicamente su contenedor/red efímeros.

El navegador usa contextos nuevos para 1280x800 y 390x844 y recorre login, verify y
logout. Intercepta y bloquea solicitudes fuera de `http://localhost:4143`, bloquea
WebSocket y service workers, y cuenta errores de página/CSP. El runner tiene límite
global de 180 s, acciones de 10 s, navegación de 15 s y paso CI de 5 min. El arranque
del fixture también tiene reintentos acotados. No guarda trazas, capturas, cookies,
URLs firmadas ni stacks de errores que puedan incluir capabilities.

`output/browser/result.json` conserva booleanos, estados, tamaño de ventana y versión
Chromium como evidencia de CI durante 14 días. El proceso falla si falta una etapa o
falla una comprobación; una ejecución preparada no se documenta como PASS. El chequeo
CSP cubre el documento de verificación; no es una auditoría exhaustiva del navegador.

## OBS real: fallo bloqueante

OBS Studio **32.2.2** instalado, arrancado con XDG_CONFIG_HOME temporal y colección
`F2 synthetic`, sin streaming ni grabación de salida. Tras detectar fuentes de audio
por defecto se detuvo esa instancia; el segundo arranque usó colección explícita y
servidores de audio inaccesibles. La configuración habitual de OBS no se modificó.

Comando de prueba (rutas locales sintéticas):

```sh
OBS_WS_URI=ws://127.0.0.1:4457 OBS_PASSWORD_FILE=/ruta/privada/obs-password \
SERVER_URL=http://127.0.0.1:4143 TEST_HANDLE=alice ARTIFACT_DIR=/ruta/privada/evidencia \
python3 scripts/test_obs_f2.py
```

Resultado **FAIL**, no sustituido por Chromium: el caso HTTP sin token devuelve 401,
pero `obs_f2_401_unauthorized.png` está completamente transparente. El log de OBS
registra `CEF failed to initialize. Exit code: 28`; obs-browser 2.26.9 informa CEF
152.0.7977.83 en runtime y 151.3.17 al compilar. No se ha confirmado la causa exacta
ni alterado paquetes del sistema/desactivado seguridad para conseguir verde.

Artefactos de esta sesión: `/tmp/chat-overlay-43/obs-test.log`, `obs.log`,
`obs-artifacts/obs_f2_401_unauthorized.png`. La instancia aislada fue detenida.
El primer intento sin variables gráficas abortó en Qt antes de arrancar; el segundo
sí llegó a OBS, pero no logró inicializar CEF. No se considera validación OBS superada.

## Pendientes de #43

- Resolver CEF en un entorno OBS compatible y repetir la candidata final integrada.
- Ejecutar y revisar el nuevo runner CI tras publicar la PR; todavía no se ha
  ejecutado Playwright en esta candidata. La evidencia interactiva anterior es T3.
- Ampliar E2E a caducidad/reautenticación, reconexión sin duplicados, inicialización
  remota real y cuotas con el validador aprobado #49; no confundir fixtures con proveedor.
- Repetir después de integrar PostgreSQL/RLS y cuarentena. #43 permanece abierto.
