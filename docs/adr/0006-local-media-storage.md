# ADR 0006 — Disco local para multimedia inicial — Refs #62

Estado: dirección aprobada por el usuario el 07-10-2026; implementación y
validación en curso. No acredita subidas operativas ni sustituye SEC-17.

La primera instalación usa el disco del guest9502. R2/S3 sigue disponible como
backend alternativo; su contratación y facturación quedan fuera de esta unidad.
No se añaden dependencias: aplicación OTP y coordinador Python ya aprobados.

El navegador reserva cuota y carga bytes mediante una ruta autenticada del mismo
origen. Sesión, token de subida, tamaño, tipo, estado pending y perfil se verifican
antes de aceptar contenido y de nuevo antes de persistir. El servidor remite
bytes acotados a un control privado fijo; no decodifica archivos ni recibe rutas
de filesystem. La capacidad de subida no se coloca en la URL.

El coordinador guarda originales en un directorio privado y salidas en otro.
Los nombres físicos son SHA-256 de claves validadas, sin segmentos aportados por
el usuario. Aperturas con O_NOFOLLOW, descriptores de directorio retenidos y
archivos regulares; creación exclusiva, fsync y metadatos durables. Borrado
registra una tombstone antes de eliminar, impidiendo PUT tardío sobre esa clave.
El servicio conserva esa evidencia y falla cerrado al alcanzar sus límites.

El adaptador reutiliza Coordinator y normalize_isolated sin modificar archivos
ligados al VEX aprobado. El decoder conserva imagen/digests/restricciones: sin
red, secretos ni Docker socket; salidas PNG estático y WAV máximo10s. El launcher
del operador posee autoridad Docker y solo admite operaciones tipadas; eso no
convierte el proceso público en una sandbox ni cierra ARCH-06.

El control se escucha únicamente en loopback durante pruebas y en la interfaz
privada del bridge dedicado al desplegar; token independiente y firewall limitado
al backend. No se comparte el socket Docker con aplicación ni decoder.

Límite inicial de contenido local:256MiB, con2GiB libres mínimos antes de escribir,
además de cuotas de perfil/ledger. Registros de almacenamiento y tombstones
acotados a4096; journal del coordinador mantiene su límite128. Directorios,
SQLite y copias privados. Reinicio conserva metadatos; archivos incompletos o
huérfanos no se publican ni se sobrescriben y requieren conciliación offline.

Solo salidas ready/active de ledger pueden servirse por HTTP, con tipo fijo,
nosniff y hash verificado. Son artefactos publicados, como el CDN R2 del contrato;
los originales nunca tienen una ruta pública. Borrar o retirar el objeto elimina
su acceso. No se declara que la URL de una salida pública sea autorización privada.

El backend queda ligado al inventario. Cambiar local↔R2 con objetos existentes
requiere migración y conciliación del operador; un cambio de variable no migra
bytes ni permite borrar objetos del backend anterior. Rollback conserva archivos
y journal, desactiva subidas y vuelve a imagen/config previas tras conciliar los
nuevos campos. No restaurar una DB antigua sobre escrituras posteriores.

Aceptación: flujo completo panel/PUT/decoder/ledger/representación; pruebas A/B,
replay, symlink/traversal, falsificación MIME, límites, cancelación y reinicio;
restricciones reales del decoder, escaneo ligado a imagen, prueba en Benten y
validación OBS separada. Backup en el mismo guest no constituye backup externo.
