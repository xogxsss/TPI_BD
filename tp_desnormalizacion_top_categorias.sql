/*
=============================================================================
DESNORMALIZACIÓN CONTROLADA -- TOP 5 CATEGORÍAS POR VENTAS DEL DÍA
Archivo : tp_desnormalizacion_top_categorias.sql
Motor   : PostgreSQL 17
Base    : foodstore_dev
Autora  : Agustina Micaela Guzmán
=============================================================================
*/


-- ============================================================
-- PASO 1 -- VISTA MATERIALIZADA: mv_ventas_categoria_diario
-- Precalcula facturación agrupada por fecha y categoría.
-- Agrupa por fecha (no filtra CURRENT_DATE) porque PostgreSQL
-- rechaza funciones volátiles en el DDL de una MV.
-- ============================================================

DROP MATERIALIZED VIEW IF EXISTS mv_ventas_categoria_diario CASCADE;

CREATE MATERIALIZED VIEW mv_ventas_categoria_diario AS
SELECT
    DATE(ped.fecha_hora)                              AS fecha,
    c.nombre                                          AS categoria,
    SUM(dp.cantidad * dp.precio_unitario_historico)   AS total_vendido
FROM detalle_pedido dp
JOIN producto  pr  ON pr.id_producto  = dp.id_producto
JOIN categoria c   ON c.id_categoria  = pr.id_categoria
JOIN pedido    ped ON ped.id_pedido   = dp.id_pedido
GROUP BY DATE(ped.fecha_hora), c.nombre;


-- ============================================================
-- PASO 2 -- ÍNDICE ÚNICO: idx_mv_ventas_fecha_cat
-- Requerido por REFRESH CONCURRENTLY y acelera el filtro
-- WHERE fecha = CURRENT_DATE en la consulta del Top 5.
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_ventas_fecha_cat
    ON mv_ventas_categoria_diario (fecha, categoria);


-- ============================================================
-- PASO 3 -- FUNCIÓN DE REFRESCO: fn_refrescar_top5_categorias
-- Encapsula el refresco concurrente para invocación externa
-- (pg_cron, cron del SO, pgAgent, etc.).
-- ============================================================

DROP FUNCTION IF EXISTS fn_refrescar_top5_categorias() CASCADE;

CREATE OR REPLACE FUNCTION fn_refrescar_top5_categorias()
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_ventas_categoria_diario;
END;
$$;


-- ============================================================
-- CONSULTA DE USO -- Top 5 del día sobre la MV
-- ============================================================
--   SELECT categoria, total_vendido
--   FROM   mv_ventas_categoria_diario
--   WHERE  fecha = CURRENT_DATE
--   ORDER  BY total_vendido DESC
--   LIMIT  5;

-- ============================================================
-- PASO 4 -- MEDICIÓN DE RENDIMIENTO
-- ============================================================

EXPLAIN ANALYZE
SELECT 
    categoria, 
    total_vendido
FROM mv_ventas_categoria_diario
WHERE fecha = CURRENT_DATE
ORDER BY total_vendido DESC
LIMIT 5;


-- ============================================================
-- PASO 5 -- AUDITORÍA DE CONSISTENCIA (EXCEPT bidireccional)
-- Resultado esperado: 0 filas.
-- ============================================================

WITH datos_3fn AS (
    SELECT 
        c.nombre AS categoria,
        SUM(dp.cantidad * dp.precio_unitario_historico) AS total_vendido
    FROM detalle_pedido dp
    JOIN producto pr ON pr.id_producto = dp.id_producto
    JOIN categoria c ON c.id_categoria = pr.id_categoria
    JOIN pedido ped  ON ped.id_pedido  = dp.id_pedido
    WHERE DATE(ped.fecha_hora) = CURRENT_DATE
    GROUP BY c.nombre
),
datos_mv AS (
    SELECT 
        categoria,
        total_vendido
    FROM mv_ventas_categoria_diario
    WHERE fecha = CURRENT_DATE
)
(
    SELECT categoria, total_vendido FROM datos_3fn
    EXCEPT
    SELECT categoria, total_vendido FROM datos_mv
)
UNION ALL
(
    SELECT categoria, total_vendido FROM datos_mv
    EXCEPT
    SELECT categoria, total_vendido FROM datos_3fn
);
