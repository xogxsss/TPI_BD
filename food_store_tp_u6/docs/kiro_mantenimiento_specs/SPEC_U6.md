# SPEC_U6 — Plan de Mantenimiento y Respaldo | Food Store

## 1. Objetivo del Plan de Mantenimiento

Garantizar la disponibilidad, integridad y recuperabilidad de la base de datos `foodstore`
(PostgreSQL 17, Windows x86_64) mediante tareas automatizadas de respaldo, monitoreo de salud,
mantenimiento de estadisticas y validacion periodica de restauracion. Todas las tareas se
ejecutan con el rol `admin_datos` (DB Owner). Las credenciales se leen exclusivamente desde
`%APPDATA%\postgresql\pgpass.conf`; queda prohibido hardcodearlas en cualquier script.
La base `foodstore` nunca recibe operaciones destructivas; las pruebas de restauracion se
realizan sobre la base descartable `foodstore_restore_test`.

---

## 2. Tabla de Tareas Programadas y Evidencias

| # | Tarea | Frecuencia | Script / Consulta | Accion | Evidencia y Criterio de Exito |
|---|---|---|---|---|---|
| 1 | Respaldo logico | Diario 02:00 | `backup_foodstore.ps1` | `pg_dump -Fc -Z 6` sobre `foodstore` | Archivo `foodstore_YYYYMMDD_HHMM.dump`; verificacion con `pg_restore --list`; hash SHA-256 via `Get-FileHash`; retencion 14 dias; log con `$LASTEXITCODE -eq 0` |
| 2 | Chequeo de salud | Diario 03:00 | `health_check.sql` via `psql` | Consulta `pg_stat_activity`, `pg_stat_database`, `pg_stat_user_tables` | Log fechado con metricas de conexiones, tamano de BD, sesiones bloqueadas y transacciones activas; sin errores de ejecucion |
| 3 | Revision de mantenimiento | Semanal Dom 03:30 | `maintenance.sql` via `psql` | Inspecciona tuplas muertas, historial de autovacuum; ejecuta `ANALYZE` sobre `pedido`, `detalle_pedido`, `producto` | Reporte en log con estado de tablas y confirmacion de actualizacion de estadisticas del optimizador |
| 4 | Restauracion de prueba | Semanal Dom 06:00 | `restore_test.ps1` | Recrea `foodstore_restore_test`; restaura ultimo `.dump` valido con `pg_restore` | Conteos `COUNT(*)` por tabla; verificacion de integridad referencial; medicion de RTO; eliminacion final de la base descartable |

---

## 3. Criterios de Aceptacion y Reglas de Seguridad en PowerShell

- **Verificacion de `$LASTEXITCODE`:** todo script `.ps1` debe evaluar `$LASTEXITCODE` inmediatamente despues de invocar `pg_dump`, `pg_restore` o `psql`. Si el valor es distinto de `0`, el script aborta y registra el error en el log antes de salir.
- **Sin credenciales en codigo:** las contrasenas se resuelven unicamente via `pgpass.conf`. Ningun script contendra literales de contrasena ni variables de entorno con credenciales en texto plano.
- **Prohibicion de operaciones destructivas sobre `foodstore`:** `DROP DATABASE foodstore`, `TRUNCATE` o `DELETE` sin `WHERE` sobre la base principal estan estrictamente prohibidos. Cualquier operacion destructiva se ejecuta exclusivamente sobre `foodstore_restore_test`.
- **Integridad del respaldo:** todo archivo `.dump` generado debe pasar la verificacion `pg_restore --list` antes de considerarse valido. Un archivo que no supere esa prueba no se contabiliza como respaldo del dia.
- **Retencion automatica:** el script de respaldo elimina archivos `.dump` con mas de 14 dias usando `Get-ChildItem` + `Where-Object` + `Remove-Item`. La eliminacion se registra en el log.

---

## 4. Casos de Prueba Obligatorios para la Bitacora

| Caso | Descripcion | Resultado esperado |
|---|---|---|
| CP-01 | Ejecutar `backup_foodstore.ps1` manualmente y verificar el `.dump` generado | Archivo presente, `pg_restore --list` sin errores, hash SHA-256 registrado |
| CP-02 | Simular falla de `pg_dump` (BD inexistente) y verificar comportamiento del script | Script aborta, registra `$LASTEXITCODE != 0` en log, no genera archivo corrupto |
| CP-03 | Ejecutar `health_check.sql` y verificar salida de metricas | Log fechado con valores de `pg_stat_database` y sin errores de conexion |
| CP-04 | Ejecutar `maintenance.sql` y confirmar actualizacion de estadisticas | `pg_stat_user_tables.last_analyze` actualizado para las tres tablas objetivo |
| CP-05 | Ejecutar `restore_test.ps1` con el ultimo `.dump` valido | `foodstore_restore_test` creada, conteos coinciden con `foodstore`, RTO registrado, base eliminada al final |
| CP-06 | Verificar que `pgpass.conf` resuelve credenciales sin prompt interactivo | `psql` y `pg_dump` completan sin solicitar contrasena |
