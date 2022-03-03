CREATE OR REPLACE FUNCTION parse_dtrange(
    _indate jsonb,
    relative_base timestamptz DEFAULT date_trunc('hour', CURRENT_TIMESTAMP)
) RETURNS tstzrange AS $$
DECLARE
    timestrs text[];
    s timestamptz;
    e timestamptz;
BEGIN
    timestrs :=
    CASE
        WHEN _indate ? 'timestamp' THEN
            ARRAY[_indate->>'timestamp']
        WHEN _indate ? 'interval' THEN
            to_text_array(_indate->'interval')
        WHEN jsonb_typeof(_indate) = 'array' THEN
            to_text_array(_indate)
        ELSE
            regexp_split_to_array(
                _indate->>0,
                '/'
            )
    END;
    RAISE NOTICE 'TIMESTRS %', timestrs;
    IF cardinality(timestrs) = 1 THEN
        IF timestrs[1] ILIKE 'P%' THEN
            RETURN tstzrange(relative_base - upper(timestrs[1])::interval, relative_base, '[)');
        END IF;
        s := timestrs[1]::timestamptz;
        RETURN tstzrange(s, s, '[]');
    END IF;

    IF cardinality(timestrs) != 2 THEN
        RAISE EXCEPTION 'Timestamp cannot have more than 2 values';
    END IF;

    IF timestrs[1] = '..' THEN
        s := '-infinity'::timestamptz;
        e := timestrs[2]::timestamptz;
        RETURN tstzrange(s,e,'[)');
    END IF;

    IF timestrs[2] = '..' THEN
        s := timestrs[1]::timestamptz;
        e := 'infinity'::timestamptz;
        RETURN tstzrange(s,e,'[)');
    END IF;

    IF timestrs[1] ILIKE 'P%' AND timestrs[2] NOT ILIKE 'P%' THEN
        e := timestrs[2]::timestamptz;
        s := e - upper(timestrs[1])::interval;
        RETURN tstzrange(s,e,'[)');
    END IF;

    IF timestrs[2] ILIKE 'P%' AND timestrs[1] NOT ILIKE 'P%' THEN
        s := timestrs[1]::timestamptz;
        e := s + upper(timestrs[2])::interval;
        RETURN tstzrange(s,e,'[)');
    END IF;

    s := timestrs[1]::timestamptz;
    e := timestrs[2]::timestamptz;

    RETURN tstzrange(s,e,'[)');

    RETURN NULL;

END;
$$ LANGUAGE PLPGSQL STABLE STRICT PARALLEL SAFE SET TIME ZONE 'UTC';

CREATE OR REPLACE FUNCTION parse_dtrange(
    _indate text,
    relative_base timestamptz DEFAULT CURRENT_TIMESTAMP
) RETURNS tstzrange AS $$
    SELECT parse_dtrange(to_jsonb(_indate), relative_base);
$$ LANGUAGE SQL STABLE STRICT PARALLEL SAFE;


CREATE OR REPLACE FUNCTION temporal_op_query(op text, args jsonb) RETURNS text AS $$
DECLARE
    ll text := 'datetime';
    lh text := 'end_datetime';
    rrange tstzrange;
    rl text;
    rh text;
    outq text;
BEGIN
    rrange := parse_dtrange(args->1);
    RAISE NOTICE 'Constructing temporal query OP: %, ARGS: %, RRANGE: %', op, args, rrange;
    op := lower(op);
    rl := format('%L::timestamptz', lower(rrange));
    rh := format('%L::timestamptz', upper(rrange));
    outq := CASE op
        WHEN 't_before'       THEN 'lh < rl'
        WHEN 't_after'        THEN 'll > rh'
        WHEN 't_meets'        THEN 'lh = rl'
        WHEN 't_metby'        THEN 'll = rh'
        WHEN 't_overlaps'     THEN 'll < rl AND rl < lh < rh'
        WHEN 't_overlappedby' THEN 'rl < ll < rh AND lh > rh'
        WHEN 't_starts'       THEN 'll = rl AND lh < rh'
        WHEN 't_startedby'    THEN 'll = rl AND lh > rh'
        WHEN 't_during'       THEN 'll > rl AND lh < rh'
        WHEN 't_contains'     THEN 'll < rl AND lh > rh'
        WHEN 't_finishes'     THEN 'll > rl AND lh = rh'
        WHEN 't_finishedby'   THEN 'll < rl AND lh = rh'
        WHEN 't_equals'       THEN 'll = rl AND lh = rh'
        WHEN 't_disjoint'     THEN 'NOT (ll <= rh AND lh >= rl)'
        WHEN 't_intersects'   THEN 'll <= rh AND lh >= rl'
        WHEN 'anyinteracts'   THEN 'll <= rh AND lh >= rl'
    END;
    outq := regexp_replace(outq, '\mll\M', ll);
    outq := regexp_replace(outq, '\mlh\M', lh);
    outq := regexp_replace(outq, '\mrl\M', rl);
    outq := regexp_replace(outq, '\mrh\M', rh);
    outq := format('(%s)', outq);
    RETURN outq;
END;
$$ LANGUAGE PLPGSQL STABLE STRICT;



CREATE OR REPLACE FUNCTION spatial_op_query(op text, args jsonb) RETURNS text AS $$
DECLARE
    geom text;
    j jsonb := args->1;
BEGIN
    op := lower(op);
    RAISE NOTICE 'Constructing spatial query OP: %, ARGS: %', op, args;
    IF op NOT IN ('s_equals','s_disjoint','s_touches','s_within','s_overlaps','s_crosses','s_intersects','intersects','s_contains') THEN
        RAISE EXCEPTION 'Spatial Operator % Not Supported', op;
    END IF;
    op := regexp_replace(op, '^s_', 'st_');
    IF op = 'intersects' THEN
        op := 'st_intersects';
    END IF;
    -- Convert geometry to WKB string
    IF j ? 'type' AND j ? 'coordinates' THEN
        geom := st_geomfromgeojson(j)::text;
    ELSIF jsonb_typeof(j) = 'array' THEN
        geom := bbox_geom(j)::text;
    END IF;

    RETURN format('%s(geometry, %L::geometry)', op, geom);
END;
$$ LANGUAGE PLPGSQL;

CREATE OR REPLACE FUNCTION query_to_cql2(q jsonb) RETURNS jsonb AS $$
-- Translates anything passed in through the deprecated "query" into equivalent CQL2
WITH t AS (
    SELECT key as property, value as ops
        FROM jsonb_each(q)
), t2 AS (
    SELECT property, (jsonb_each(ops)).*
        FROM t WHERE jsonb_typeof(ops) = 'object'
    UNION ALL
    SELECT property, 'eq', ops
        FROM t WHERE jsonb_typeof(ops) != 'object'
)
SELECT
    jsonb_strip_nulls(jsonb_build_object(
        'op', 'and',
        'args', jsonb_agg(
            jsonb_build_object(
                'op', key,
                'args', jsonb_build_array(
                    jsonb_build_object('property',property),
                    value
                )
            )
        )
    )
) as qcql FROM t2
;
$$ LANGUAGE SQL IMMUTABLE STRICT;


CREATE OR REPLACE FUNCTION cql1_to_cql2(j jsonb) RETURNS jsonb AS $$
DECLARE
    args jsonb;
    ret jsonb;
BEGIN
    RAISE NOTICE '%',j;
    IF j ? 'filter' THEN
        RETURN cql1_to_cql2(j->'filter');
    END IF;
    IF j ? 'property' THEN
        RETURN j;
    END IF;
    IF jsonb_typeof(j) = 'array' THEN
        SELECT jsonb_agg(cql1_to_cql2(el)) INTO args FROM jsonb_array_elements(j) el;
        RETURN args;
    END IF;
    IF jsonb_typeof(j) = 'number' THEN
        RETURN j;
    END IF;
    IF jsonb_typeof(j) = 'string' THEN
        RETURN j;
    END IF;

    SELECT jsonb_build_object(
            'op', key,
            'args', cql1_to_cql2(value)
        ) INTO ret FROM jsonb_each(j);
    RETURN ret;
END;
$$ LANGUAGE PLPGSQL IMMUTABLE STRICT;

CREATE TABLE cql2_ops (
    op text PRIMARY KEY,
    template text,
    types text[]
);
INSERT INTO cql2_ops (op, template, types) VALUES
    ('eq', '%s = %s', NULL),
    ('lt', '%s < %s', NULL),
    ('lte', '%s <= %s', NULL),
    ('gt', '%s > %s', NULL),
    ('gte', '%s >= %s', NULL),
    ('le', '%s <= %s', NULL),
    ('ge', '%s >= %s', NULL),
    ('=', '%s = %s', NULL),
    ('<', '%s < %s', NULL),
    ('<=', '%s <= %s', NULL),
    ('>', '%s > %s', NULL),
    ('>=', '%s >= %s', NULL),
    ('like', '%s LIKE %s', NULL),
    ('ilike', '%s ILIKE %s', NULL),
    ('+', '%s + %s', NULL),
    ('-', '%s - %s', NULL),
    ('*', '%s * %s', NULL),
    ('/', '%s / %s', NULL),
    ('in', '%s = ANY (%s)', NULL),
    ('not', 'NOT (%s)', NULL),
    ('between', '%s BETWEEN (%2$s)[1] AND (%2$s)[2]', NULL),
    ('isnull', '%s IS NULL', NULL)
ON CONFLICT (op) DO UPDATE
    SET
        template = EXCLUDED.template;
;


CREATE OR REPLACE FUNCTION cql2_query(j jsonb, wrapper text DEFAULT NULL) RETURNS text AS $$
#variable_conflict use_variable
DECLARE
    args jsonb := j->'args';
    arg jsonb;
    op text := lower(j->>'op');
    cql2op RECORD;
    literal text;
BEGIN
    IF j IS NULL THEN
        RETURN NULL;
    END IF;
    RAISE NOTICE 'CQL2_QUERY: %', j;
    IF j ? 'filter' THEN
        RETURN cql2_query(j->'filter');
    END IF;

    IF j ? 'upper' THEN
        RETURN format('upper(%s)', cql2_query(j->'upper'));
    END IF;

    IF j ? 'lower' THEN
        RETURN format('lower(%s)', cql2_query(j->'lower'));
    END IF;

    -- Temporal Query
    IF op ilike 't_%' or op = 'anyinteracts' THEN
        RETURN temporal_op_query(op, args);
    END IF;

    -- If property is a timestamp convert it to text to use with
    -- general operators
    IF j ? 'timestamp' THEN
        RETURN format('%L::timestamptz', to_tstz(j->'timestamp'));
    END IF;
    IF j ? 'interval' THEN
        RAISE EXCEPTION 'Please use temporal operators when using intervals.';
        RETURN NONE;
    END IF;

    -- Spatial Query
    IF op ilike 's_%' or op = 'intersects' THEN
        RETURN spatial_op_query(op, args);
    END IF;


    IF op = 'in' THEN
        RETURN format(
                '%s = ANY (%L)',
                cql2_query(args->0),
                to_text_array(args->1)
            );
    END IF;



    IF op = 'between' THEN
        SELECT (queryable(a->>'property')).wrapper INTO wrapper
        FROM jsonb_array_elements(args) a
        WHERE a ? 'property' LIMIT 1;

        RETURN format(
            '%s BETWEEN %s and %s',
            cql2_query(args->0, wrapper),
            cql2_query(args->1->0, wrapper),
            cql2_query(args->1->1, wrapper)
            );
    END IF;

    -- Make sure that args is an array and run cql2_query on
    -- each element of the array
    RAISE NOTICE 'ARGS PRE: %', args;
    IF j ? 'args' THEN
        IF jsonb_typeof(args) != 'array' THEN
            args := jsonb_build_array(args);
        END IF;

        SELECT (queryable(a->>'property')).wrapper INTO wrapper
        FROM jsonb_array_elements(args) a
        WHERE a ? 'property' LIMIT 1;

        SELECT jsonb_agg(cql2_query(a, wrapper))
            INTO args
        FROM jsonb_array_elements(args) a;
    END IF;
    RAISE NOTICE 'ARGS: %', args;

    IF op IN ('and', 'or') THEN
        RETURN
            format(
                '(%s)',
                array_to_string(to_text_array(args), format(' %s ', upper(op)))
            );
    END IF;

    -- Look up template from cql2_ops
    IF j ? 'op' THEN
        SELECT * INTO cql2op FROM cql2_ops WHERE  cql2_ops.op ilike op;
        IF FOUND THEN
            -- If specific index set in queryables for a property cast other arguments to that type
            RETURN format(
                cql2op.template,
                VARIADIC (to_text_array(args))
            );
        ELSE
            RAISE EXCEPTION 'Operator % Not Supported.', op;
        END IF;
    END IF;


    IF j ? 'property' THEN
        RETURN (queryable(j->>'property')).expression;
    END IF;

    IF wrapper IS NOT NULL THEN
        EXECUTE format('SELECT %I(%L)', wrapper, j) INTO literal;
        RAISE NOTICE '% % %',wrapper, j, literal;
        RETURN format('%I(%L)', wrapper, j);
    END IF;

    RETURN quote_literal(to_text(j));
END;
$$ LANGUAGE PLPGSQL STABLE;


CREATE OR REPLACE FUNCTION paging_dtrange(
    j jsonb
) RETURNS tstzrange AS $$
DECLARE
    op text;
    filter jsonb := j->'filter';
    dtrange tstzrange := tstzrange('-infinity'::timestamptz,'infinity'::timestamptz);
    sdate timestamptz := '-infinity'::timestamptz;
    edate timestamptz := 'infinity'::timestamptz;
    jpitem jsonb;
BEGIN

    IF j ? 'datetime' THEN
        dtrange := parse_dtrange(j->'datetime');
        sdate := lower(dtrange);
        edate := upper(dtrange);
    END IF;
    IF NOT (filter  @? '$.**.op ? (@ == "or" || @ == "not")') THEN
        FOR jpitem IN SELECT j FROM jsonb_path_query(filter,'strict $.** ? (@.args[*].property == "datetime")'::jsonpath) j LOOP
            op := lower(jpitem->>'op');
            dtrange := parse_dtrange(jpitem->'args'->1);
            IF op IN ('<=', 'lt', 'lte', '<', 'le', 't_before') THEN
                sdate := greatest(sdate,'-infinity');
                edate := least(edate, upper(dtrange));
            ELSIF op IN ('>=', '>', 'gt', 'gte', 'ge', 't_after') THEN
                edate := least(edate, 'infinity');
                sdate := greatest(sdate, lower(dtrange));
            ELSIF op IN ('=', 'eq') THEN
                edate := least(edate, upper(dtrange));
                sdate := greatest(sdate, lower(dtrange));
            END IF;
            RAISE NOTICE '2 OP: %, ARGS: %, DTRANGE: %, SDATE: %, EDATE: %', op, jpitem->'args'->1, dtrange, sdate, edate;
        END LOOP;
    END IF;
    IF sdate > edate THEN
        RETURN 'empty'::tstzrange;
    END IF;
    RETURN tstzrange(sdate,edate, '[]');
END;
$$ LANGUAGE PLPGSQL STABLE STRICT SET TIME ZONE 'UTC';

CREATE OR REPLACE FUNCTION paging_collections(
    IN j jsonb
) RETURNS text[] AS $$
DECLARE
    filter jsonb := j->'filter';
    jpitem jsonb;
    op text;
    args jsonb;
    arg jsonb;
    collections text[];
BEGIN
    IF j ? 'collections' THEN
        collections := to_text_array(j->'collections');
    END IF;
    IF NOT (filter  @? '$.**.op ? (@ == "or" || @ == "not")') THEN
        FOR jpitem IN SELECT j FROM jsonb_path_query(filter,'strict $.** ? (@.args[*].property == "collection")'::jsonpath) j LOOP
            RAISE NOTICE 'JPITEM: %', jpitem;
            op := jpitem->>'op';
            args := jpitem->'args';
            IF op IN ('=', 'eq', 'in') THEN
                FOR arg IN SELECT a FROM jsonb_array_elements(args) a LOOP
                    IF jsonb_typeof(arg) IN ('string', 'array') THEN
                        RAISE NOTICE 'arg: %, collections: %', arg, collections;
                        IF collections IS NULL OR collections = '{}'::text[] THEN
                            collections := to_text_array(arg);
                        ELSE
                            collections := array_intersection(collections, to_text_array(arg));
                        END IF;
                    END IF;
                END LOOP;
            END IF;
        END LOOP;
    END IF;
    IF collections = '{}'::text[] THEN
        RETURN NULL;
    END IF;
    RETURN collections;
END;
$$ LANGUAGE PLPGSQL STABLE STRICT;
