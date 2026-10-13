# Bitácora de Asistencia IA — Unidad 5: Administración y Seguridad

El registro de uso de IA de las Unidades 1 a 4 está en `DUIA.md` (raíz del repo). A partir de la Unidad 5 se usa este archivo.

---

| Prompt enviado a la IA | Respuesta relevante recibida | Validacion o correccion humana aplicada |
|---|---|---|
| Generar un script base de roles para la U5 con 4 grupos y el login `app_web`, partiendo del esquema de la Clase 1. | Script con `REVOKE` inicial, permisos sobre vistas y `GRANT EXECUTE` sobre `sp_crear_pedido`. Usaba `PASSWORD :'app_pass'` (variable de psql). | **Propuesta incorrecta detectada:** los nombres de vistas no coincidian con el schema real, se referenciaba una tabla `usuario` que no existe en el proyecto (la entidad correcta es `cliente`), y la sintaxis de contrasena con `:'variable'` causo un error al ejecutar porque no se pasaron las variables `-v`. Se pidio correccion completa. |
| Reescribir y expandir `roles.sql` y las specs con justificaciones por rol, permiso granular por columna, `ALTER DEFAULT PRIVILEGES`, rol `admin_datos` y las funciones `fn_resetear_password` / `fn_autenticar`. | Kiro leyó el schema antes de escribir, detectó el problema con `usuario` y adaptó todo a `cliente`. Generó permisos por columna, `fn_autenticar` con mitigación de timing attack, ambas funciones con `SECURITY DEFINER`, bloque de limpieza idempotente y verificación con `information_schema`. | Se ejecutó en `foodstore_dev` y se validó la salida: roles correctos, 9 permisos de tabla, 3 permisos de columna sobre `cliente`, 5 permisos de rutina. Quedó pendiente el `WARNING` de `sp_crear_pedido` inexistente. |
| Las contraseñas con `:'variable'` siguen dando error de sintaxis al ejecutar sin `-v`. Reemplazarlas por valores literales de sandbox. | Kiro cambió `:'app_pass'` por `'app_web_pass_dev'` y `:'admin_pass'` por `'admin_datos_pass_dev'`, y actualizó el comentario de cabecera del script. | Se reejecutó y corrió limpio. Valores de sandbox aceptables para el entorno de desarrollo. |
| `sp_crear_pedido` no existe en la BD, lo cual genera un `WARNING`. Crearlo en un archivo separado con lógica real. | Se generó `procedimientos.sql` con validación de stock, `SELECT … FOR UPDATE` para evitar condiciones de carrera, captura del precio histórico y `RAISE EXCEPTION` ante stock insuficiente o producto inactivo. | Se ejecutó `procedimientos.sql` primero y luego `roles.sql`. El warning desapareció y la tabla de rutinas mostró `rol_app_escritura | sp_crear_pedido | EXECUTE`. |
| ¿La columna `contrasena_hash` debería estar en `schema.sql` o solo aplicarla manualmente en el sandbox? | Kiro recomendó agregarla al schema para que al recrear la BD desde cero la columna esté disponible, y la agregó directamente a la definición de `cliente`. | Modificación del archivo raíz autorizada explícitamente por el equipo (excepción al principio de inmutabilidad del AGENTS.md). Se verificó que el schema sigue siendo válido. |
| Revisar si las specs reflejan el estado final ejecutado. | Kiro detectó que la firma de `sp_crear_pedido` no estaba documentada, que el flujo de deploy no mencionaba `procedimientos.sql` como paso previo, y que REQ-SEC3 no describía los dos pasos. Actualizó las secciones afectadas. | Se revisó el contenido final. La documentación quedó alineada con lo ejecutado y verificado. |
| Generar el log de verificación de permisos (`log_verificacion_roles.txt`) ejecutando la sección 8 de `roles.sql`. | Se capturó la salida completa: `\du`, `\ddp`, permisos de tabla, columna y rutina. PowerShell agregó ruido de stderr por los NOTICE de pgcrypto. | Se limpió el bloque de error de PowerShell del log (no era un error real) y se agregó un encabezado explicativo. Todos los permisos coinciden con la spec. |
| `rol_reportes` no aparecía en `information_schema.role_table_grants`. ¿Tiene el permiso o no? | Kiro explicó que `information_schema` no expone vistas materializadas y verificó el permiso con `has_table_privilege()`, que devolvió `t`. | Se agregó la consulta y su resultado al log como verificación adicional. Permiso confirmado. |
| Auditoría del `roles.sql` por Gemini: identificó 4 problemas — `fn_autenticar` otorgado a `rol_soporte`, bucle dinámico sobre `pg_proc` innecesario, `v_hash IS NOT NULL` faltante, y `mv_ventas_categoria_diario` ignorada. | Kiro había identificado los mismos puntos en su propia auditoría. Se aplicaron las 4 correcciones. | **Correcciones aplicadas:** (1) revocado `EXECUTE fn_autenticar` de `rol_soporte` — solo `app_web` autentica; (2) reemplazado el bucle dinámico por `GRANT EXECUTE ON PROCEDURE sp_crear_pedido(BIGINT, forma_pago_enum, JSONB)`; (3) agregado `v_hash IS NOT NULL` en `fn_autenticar`; (4) agregado `GRANT SELECT ON mv_ventas_categoria_diario TO rol_reportes` y corregida la spec que la daba como inexistente. |
| **Parte B — Activar auditoría nativa.** Configurar `log_connections`, `log_disconnections`, `log_statement` y `log_line_prefix`. Ejecutar una secuencia de prueba y capturar el log. | Kiro aplicó los parámetros con `ALTER SYSTEM` + `pg_reload_conf()`, generó `auditoria_test.sql` y capturó el fragmento de log resultante en `log_auditoria_prueba.txt`. Redactó `informe_auditoria.md` con el análisis de los 4 puntos de la consigna. | Se verificó que el log registra conexión, INSERT, UPDATE, DELETE y login fallido con el nuevo prefijo. El SELECT no aparece (comportamiento correcto con `log_statement=mod`). El informe fue revisado y aceptado sin cambios. |
| **Parte B — Verificacion adicional de `rol_reportes`.** `information_schema` no mostraba permisos de la vista materializada. | Kiro explicó la limitación y verificó con `has_table_privilege()`. Resultado: `t`. Se agregó la consulta al log como evidencia complementaria. | Verificación aceptada. Se documentó la limitación de `information_schema` frente a vistas materializadas. |
| **Parte C — Simulacro de incidente.** Diseñar y ejecutar un script con fuerza bruta via `fn_autenticar`, login exitoso, lectura masiva y escalamiento de privilegios. | Kiro generó `simulacro_incidente.sql`. En la primera ejecución, el GRANT de `admin_datos` se ejecutó como `postgres` (superusuario) y tuvo éxito — fue revertido y corregido con `SET ROLE app_web`. En la ejecución final el escalamiento falló correctamente. | Se documentó el error del primer intento como hallazgo esperado (el superusuario puede escalar cualquier rol). El escalamiento con `app_web` falló como corresponde. |
| **Parte C — Reconstrucción por IA del log anonimizado.** Se entregó `log_simulacro_anonimizado.txt` sin contexto adicional. | Kiro identificó la secuencia correctamente pero afirmó que "todas las llamadas a `fn_autenticar` terminaron en ERROR" — sin detectar que el 4to intento fue exitoso a nivel lógico. También caracterizó la sesión como "un atacante" sin evidencia de acceso externo. | **Error de la IA documentado:** confundió un error interno de función (columna faltante) con un fallo de autenticación. El contraste completo y la decisión de contención se redactaron de forma independiente en `informe_incidente.md`. |
| **Parte D — Anonimizacion de datos personales.** Construir `cliente_anon` con datos sinteticos deterministas y demostrar que los resultados agregados son equivalentes a los de la tabla real. | Kiro genero `usuario_anon.sql` con sustituciones deterministas para nombre, email, telefono y direccion (conservando `id_cliente` para mantener el JOIN con `pedido`). Propuso una consulta de equivalencia basada en distribucion por mes de primer pedido y rango de pedidos por cliente. | Se ejecuto el script. Verificacion de conteo: 20000 == 20000. Ambas consultas devolvieron los mismos 6 grupos. EXCEPT en ambas direcciones retorno 0 filas. Equivalencia confirmada. Evidencia adjunta en `verificacion_equivalencia.md`. |

---

## Caso mas significativo de error de la IA

El error mas significativo ocurrio en la Parte C, durante la reconstruccion del log anonimizado.
La IA recibio un fragmento de log donde `fn_autenticar` fallaba en cada llamada con el mensaje
"no existe la columna c.contrasena_hash" — un error interno de la funcion, no de autenticacion.
La IA concluyo que "todas las llamadas terminaron en ERROR" y que el atacante "no logro
autenticarse", cuando en realidad el cuarto intento paso correctamente la logica de comparacion
de contrasena y retorno el `id_cliente`. La IA confundio un error de implementacion con un
fallo de autenticacion porque ambos producen la misma salida visible en el log: una linea de
ERROR. La deteccion fue posible porque el equipo conocia el script ejecutado y sabia que la
cuarta llamada usaba la contrasena correcta — conocimiento que el log por si solo no provee.
Este caso ilustra el limite central de la auditoria basada en logs nativos: el log registra que
algo fallo, pero no siempre permite distinguir por que fallo ni si, a pesar del error, el efecto
buscado por el atacante se produjo de todas formas.

---

## Revision del historial de Git

El historial refleja el avance por partes con mensajes legibles:

```
c2d9c67  docs(u5): agrega entrada Parte D a bitacora
51298a1  feat(u5/parted): anonimizacion y verificacion de equivalencia
95757bd  docs(u5): actualiza bitacora con partes B y C
9e1dae0  style(u5): elimina todos los emojis de documentacion y specs
e4339e5  feat(u5/partec): simulacro de incidente de seguridad
cae68df  feat(u5/parteb): auditoria nativa PostgreSQL
850e58d  fix(u5): corrige permisos y funciones segun auditoria
65b53ea  docs(u5): specs, log de verificacion y bitacora de la Parte A
89fa18a  feat(u5): agrega sp_crear_pedido, roles, permisos y funciones de seguridad
0960d18  feat(schema): agrega contrasena_hash a tabla cliente
```

El historial es correcto. Cada commit corresponde a una unidad de trabajo identificable.

Una cosa que se haria distinto: el commit `style(u5): elimina todos los emojis` no deberia
existir — implica que los archivos se revisaron despues de commiteados. La convencion correcta
es no commitear hasta verificar que el contenido cumple con los estandares del proyecto
(sin emojis, sin contrasenas en texto plano, etc.). En la proxima entrega, la revision de
formato seria parte del paso previo al `git add`, no un commit correctivo posterior.
