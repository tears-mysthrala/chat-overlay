# Modelo de amenazas inicial F0

## Activos

Código, configuración de operación, futuras credenciales de plataformas, disponibilidad del proceso y separación entre overlays. F0 no maneja credenciales ni contenido de chat persistente.

## Entradas y actores

La entrada actual es el propio artefacto del repositorio y la configuración de build. En F1 se añadirán selectores públicos y eventos upstream no confiables. Actores considerados: visitante, operador, plataforma upstream, dependencia comprometida y atacante con capacidad de enviar texto.

## Abusos y mitigaciones

| Riesgo | Mitigación F0 | Riesgo residual |
| --- | --- | --- |
| XSS/inyección desde chats | No existe renderizador ni entrada de chat | Requiere pruebas DOM antes de F1 |
| SSRF por selector de canal | No se aceptan URLs ni peticiones de red | Validar destinos y DNS en issues de conectores |
| Fuga entre perfiles | No hay perfiles ni estado compartido | Diseñar aislamiento antes de F2 |
| Robo de tokens | No hay tokens ni secretos en fixtures/logs | Revisar custodia antes de F2/F3 |
| Agotamiento de recursos | Sin listener ni ingestión; contrato fija límites futuros | Probar límites y backpressure en F1 |
| Dependencia comprometida | Dependencias Mix vacías; workflow con permiso mínimo | Añadir SBOM/escaneo de artefactos en F0 posterior |
| Administración expuesta | No hay endpoints administrativos | Revisar publicación antes de cualquier despliegue |

No se ejecuta código desde datos, no se crean átomos desde entrada externa, no se usa deserialización de términos no confiables ni shell controlada por usuario.
