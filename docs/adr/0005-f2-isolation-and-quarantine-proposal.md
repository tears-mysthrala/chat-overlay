# ADR 0005 — Propuesta para cerrar SEC-13 y SEC-17 (#51, #49)

**Estado: A y B aprobadas expresamente por el usuario el 05-10-2026 para implementación y pruebas locales.**
La autorización incluye Postgrex y las dependencias/restricciones descritas; excluye
infraestructura y cuentas reales, push, PR externa, merge y despliegue. Esta rama
implementa solo A (#51); B se realiza en una unidad independiente. La aprobación
no acredita controles terminados. #56 corrige
persistencia JSON; #57 corrige inventario/cuota. Ninguna satisface por sí sola RLS
o validación de formatos. Se solicita aprobación de implementación local en dos
unidades separadas; los datos y servicios reales quedan fuera. Ver la implementación
y sus límites en [almacenamiento PostgreSQL](../postgres-storage.md).

## A. Almacenamiento privado con PostgreSQL RLS (#51)

Adoptar PostgreSQL autoalojado, referencia de SEC-13, y Postgrex como dependencia de
producción nueva, con versiones soportadas revisadas y fijadas antes de incorporar.
Sin Ecto inicialmente: esquema pequeño y SQL parametrizado explícito.

- Rol de migraciones/propietario separado del rol runtime; runtime sin superusuario,
  BYPASSRLS ni propiedad de tablas. Aplicar RLS y FORCE ROW LEVEL SECURITY a perfiles,
  cuentas y objetos; políticas USING/WITH CHECK para handle/identidad autorizada.
- El contexto se establece dentro de cada transacción y no sobrevive a su devolución
  al pool. Derivarlo de la autorización del servidor, nunca del handle recibido sin
  verificar. Ausencia de contexto: no filas y escritura denegada.
- La ingestión/coordinación global no usa el rol de una petición pública: delimitar
  operaciones y credenciales de servicio con grants mínimos y sin superficie HTTP
  que acepte SQL, identificadores de rol ni contexto arbitrario.
- Migración offline validada, desde copia, preservando ciphertext, versiones de
  cuenta, hashes capability e inventario. Sin migración automática al arrancar.
  Ensayar con datos sintéticos y comparar conteos/digests antes de cambiar el origen.
- Regresiones con PostgreSQL real: lectura/escritura/cruce A-B, pool reutilizado,
  rollback/excepciones, consultas sin contexto y rol runtime efectivo. No sustituirlas
  por mocks ni consultas del propietario.
- Rollback antes del corte: mantener JSON intacto. Tras aceptar escrituras en DB:
  exportación validada offline y conciliación antes de volver; no restaurar JSON viejo.

Límite reconocido: RLS no protege de una aplicación comprometida que pueda elegir
cualquier contexto permitido a sus credenciales. Separar identidades de proceso y
superficies privadas según ARCH-06 sigue siendo un gate de publicación (#39).

## B. Cuarentena privada y validación aislada (#49)

Sustituir la subida directa al objeto público por reserva y PUT a cuarentena privada.
El lector/overlay nunca reciben su URL. El resultado público será una clave nueva
que el cliente no puede escribir; una reutilización del PUT solo afecta cuarentena.

Propuesta de componentes y dependencias a aprobar:

1. Coordinador de transferencia limitado a R2 y al inventario: descarga acotada
   (2 MiB audio/512 KiB imagen), SHA-256 de bytes, entrada de solo lectura para el
   validador y promoción del resultado. No entrega credenciales R2/OAuth al decoder.
   Sus permisos separan lectura de cuarentena y escritura del prefijo validado.
   El backend HTTP principal conserva solo control y metadatos.
2. Validador desechable con FFmpeg/ffprobe en imagen propia fijada y auditada.
   Sin red, secretos, datos de otros perfiles ni socket Docker; usuario sin
   privilegios, raíz read-only, capacidades vacías, no-new-privileges, PID 32,
   memoria 256 MiB, 1 CPU y 10 s de tiempo total. Un job por instancia y cola
   acotada; launcher del operador, no shell ni argumentos del usuario.
3. Normalizar imagen a PNG estático máximo 1024x1024/512 KiB; audio a WAV PCM mono
   48 kHz, máximo 10 s/2 MiB. Rechazar animaciones, dimensiones/duración excesivas,
   streams adicionales y decodificación incompleta. Esto restringe funcionalidades
   respecto de los formatos de entrada; requiere aceptación explícita.
4. El coordinador vuelve a comprobar tamaño/estructura permitida de la salida,
   calcula su hash y lo liga al job, perfil y hash de entrada. Publica la salida
   con nombre inmutable derivado del hash; actualiza inventario solo tras éxito.
   Nunca copia a público el original basándose en un reporte separado del archivo.
5. Mantener reserva/coste de cuarentena y salida hasta DELETE confirmado. Conciliar
   objetos abandonados, subidas reutilizadas e interrupciones sin liberar cuota
   antes de tiempo. Rechazos quedan privados, con retención acotada definida en #48.

Pruebas: formatos válidos e inválidos sintéticos, extensiones engañosas, límites de
bytes/dimensiones/duración, timeout/kill, reporte o salida manipulados, hash cambiado,
reutilización de PUT, fallo de promoción y aislamiento efectivo del contenedor.
Sin datos privados, malware real ni tráfico a una cuenta R2 del operador.

Rollout solo tras revisión: mantener subidas no activadas hasta cumplir esta cadena;
permitir el resto del panel según gates existentes. Un validador sin detecciones no
certifica inocuidad, legalidad ni licencia del contenido. Este diseño necesita pruebas
reales de aislamiento; una tarea BEAM o una comprobación MIME no lo sustituye.

## Decisión solicitada

Aprobar A y B para implementación y validación local, con las dependencias nuevas y
las restricciones de formato anteriores. No incluye cambios de infraestructura real,
credenciales, permisos de buckets, DNS, producción ni merge. Si solo se aprueba una
unidad, ejecutar esa unidad y mantener la otra como bloqueo explícito de F2.
