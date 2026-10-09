# Compatibilidad de build Postgrex — 09-10-2026

Refs #70. Base95d1539, rama chore/70-postgrex-warning, worktree independiente.
El aviso se reproduce en Postgrex0.22.4 sobre Elixir1.20.4: la opción
`xref: [exclude: [Jason]]` está deprecada. La versión publicada verificada en
[Hex](https://hex.pm/packages/postgrex/versions) sigue siendo0.22.4;
[upstream](https://github.com/elixir-ecto/postgrex/blob/master/mix.exs) utiliza
`elixirc_options: [no_warn_undefined: [Jason]]` para ese mismo módulo opcional.

Se conserva versión/lock de Hex. Antes de compilar dependencias, el build verifica
SHA256 del mix.exs original63d6f2696a3df8677167f571bbd74da7fb93bc995c17a4aa0f31e16782d5720c
y sustituye únicamente esa opción. Cualquier otro contenido hace fallar el build.
No se silencian avisos globales ni se modifica el código runtime del cliente.
La configuración efectiva y el parche quedan identificados en las propiedades
CycloneDX del componente Postgrex; el checksum del paquete original sigue siendo
el del archivo Hex, no se presenta como checksum del árbol modificado.

Regresión: aplicar sobre original, comprobar resultado exacto y rechazar tanto
segunda aplicación como modificación inesperada. Build limpio pasa formato y
compilación sin el aviso. PostgreSQL/RLS:26 pruebas con cada seed0/424242 y
arranque completo, persistencia y reinicio PASS. Primer comando local de migración
usó un nombre de rol incorrecto y falló; se corrigió a overlay_migrator conforme
al fixture, sin cambiar privilegios ni SQL.

Smoke de release PASS. Imagen72adb938a2a7c6d05349fa403e752f9e28e4464418221cf178db01fea9bbfb68,
SBOM295 componentes y esquema válido. Estática específica sin hallazgos,
escáner sin fugas. ExUnit328 PASS seed485713. Auditoría: cero findings activos,
cuatro matches conservados bajo VEX vigente. Auto Review Codex exit0, sin
hallazgos accionables, alcance limitado al bundle. La suite emitió un log
GenServer no process durante cierre de stream; no causó fallo de prueba y no se
presenta esta ejecución como ausencia de logs de error. No se desplegó producción.

Rollback: revertir script, etapa de build, metadatos y regresión; no hay migración
de datos ni actualización del driver. El vencimiento de VEX no se modifica.
