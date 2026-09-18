-- ─────────────────────────────────────────────────────────────────────────────
-- L1, step 1: what is each column, really?
--
-- Judged from the values, the column's neighbours and a few whole example rows --
-- never from the column name alone, because a wrong name is one of the defects
-- we are hunting. One request per column, with the whole battery batched into it.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE MACRO profile_semantic_types() AS json_object(
    'person_name',           'Names of individual people: given, family or full names.',
    'organization_name',     'Names of companies, institutions, teams or other organizations.',
    'email_address',         'Email addresses.',
    'phone_number',          'Telephone numbers in any national format.',
    'street_address',        'Street lines of a postal address: number, street, unit.',
    'city',                  'City, town or locality names.',
    'region_or_state',       'States, provinces, counties or comparable subdivisions.',
    'postal_code',           'Postal or ZIP codes.',
    'country',               'Country names or country codes.',
    'geo_coordinate',        'Latitude, longitude or a coordinate pair.',
    'url',                   'Web addresses or URIs.',
    'ip_address',            'IPv4 or IPv6 addresses.',
    'file_path',             'Filesystem paths or object-storage keys.',
    'uuid',                  'UUIDs or GUIDs.',
    'sequential_id',         json_object(
        'what',    'A counter-like primary key: dense integers, mostly increasing.',
        'not_for', 'Random or hashed identifiers, which are opaque_identifier.'),
    'opaque_identifier',     json_object(
        'what',    'A machine identifier with no human meaning: hashes, random tokens, surrogate keys.',
        'not_for', 'Product codes a person would recognise, which are sku_or_product_code.'),
    'foreign_key_reference', 'An identifier that points at rows in some other table.',
    'sku_or_product_code',   'Catalogue, part, SKU or model codes that name a real product.',
    'currency_amount',       'Monetary values, with or without a currency symbol.',
    'percentage',            'Percentages, rates or ratios.',
    'physical_measurement',  'Physical quantities: weight, length, volume, temperature, speed.',
    'count_or_quantity',     'Counts of things: units ordered, items in stock, page views.',
    'duration',              'Elapsed time: seconds, minutes, days, ISO 8601 durations.',
    'timestamp',             'A point in time carrying both date and time.',
    'date',                  'A calendar date with no time component.',
    'boolean_flag',          'Two-valued flags, however they are spelled.',
    'status_code',           json_object(
        'what',     'A value drawn from a small fixed lifecycle: pending, shipped, cancelled; or A/C/P.',
        'not_for',  'Open-ended labels that merely repeat, which are category_label.'),
    'category_label',        'An open-ended classification or tag drawn from a larger vocabulary.',
    'free_text',             'Prose written by a person: notes, descriptions, comments, reviews.',
    'json_blob',             'Serialized structured data stored in a single field.',
    'encoded_binary',        'Base64, hex or otherwise encoded binary content.',
    'credential_or_secret',  'Passwords, API keys, tokens or anything else that grants access.',
    'national_id_number',    'Government identifiers: SSN, NI number, tax or passport numbers.',
    'payment_card',          'Payment card numbers or fragments of them.',
    'version_string',        'Software or schema versions.',
    'language_or_locale',    'Language tags or locale identifiers.',
    'currency_code',         'ISO currency codes such as USD or EUR.',
    'other',                 'None of the listed types fits what these values actually are.'
);

CREATE OR REPLACE MACRO profile_roles() AS json_object(
    'identifier',  'Identifies the row itself.',
    'foreign_key', 'Points at a row in another table.',
    'measure',     'A quantity you would sum, average or otherwise aggregate.',
    'category',    'Groups rows together; you would filter or GROUP BY on it.',
    'free_text',   'Human-written prose, not meant for aggregation.',
    'temporal',    'Positions the row in time.',
    'status_flag', 'Records where the row sits in some lifecycle.',
    'derived',     'Computed from other columns rather than recorded independently.',
    'metadata',    'Bookkeeping about the record: who loaded it, when, from where.'
);

CREATE OR REPLACE MACRO profile_discovery_questions() AS json_object(
    'semantic_type', q_choice(
        json_object(
            'question', 'Judging by the values in `sample_values`, what kind of real-world information does this column actually hold?',
            'note',     'Judge the values themselves. The column name in `column.name` is a hint that may be wrong, and detecting that it is wrong is part of the job.'),
        profile_semantic_types()),

    'role', q_choice(
        'How is this column used in `table`, given its values and the other columns in `sibling_columns`?',
        profile_roles()),

    'name_matches_values', q_noul(
        'Does the column name in `column.name` accurately describe what is actually stored in `sample_values`?',
        json_object(
            'true',  'The name is an honest description of the values.',
            'false', json_object(
                'what',     'The name misdescribes the values, or describes something narrower or broader than what is there.',
                'examples', json_array(
                    'a column named `email` holding phone numbers',
                    'a column named `price` holding free-text pricing notes',
                    'a column named `date` holding a full timestamp with a timezone')))),

    'sensitive', q_noul(
        'Do any of the values in `sample_values` contain personal or otherwise sensitive information about an identifiable person?',
        json_object(
            'true',  json_object(
                'what',     'At least one value carries personal or sensitive data, even incidentally.',
                'examples', json_array(
                    'names, personal email addresses or phone numbers',
                    'national identifiers, payment card numbers, credentials',
                    'a free-text note that happens to mention someone''s medical or financial details')),
            'false', 'Nothing here identifies a person or exposes a secret.')),

    'format_consistency', q_score(
        'How consistently are the values in `sample_values` formatted? Consider units, separators, casing, date conventions, and whether the same fact is written the same way twice.',
        json_array(
            json_object('summary', 'Uniform. Every value follows one format, with one unit convention.',
                        'signals', json_array('identical shape throughout', 'a single unit or none needed')),
            json_object('summary', 'Nearly uniform. One dominant format with rare cosmetic variation.',
                        'signals', json_array('stray whitespace or casing differences')),
            json_object('summary', 'Mixed but reconcilable. A few clear formats that map onto each other.',
                        'signals', json_array('both `2024-01-05` and `05/01/2024`', 'some values quote a unit and some do not')),
            json_object('summary', 'Inconsistent. Several formats or units coexist and reconciling them needs guesswork.',
                        'signals', json_array('`12 kg` next to `26.4` with no unit', 'currency symbols on some values only')),
            json_object('summary', 'Incoherent. The column holds values of genuinely different kinds.',
                        'signals', json_array('numbers, dates and prose in the same column')))),

    'sentinels', q_noul(
        'Do any values in `sample_values` stand in for missing data rather than being real data?',
        json_object(
            'true',  json_object(
                'what',     'Placeholder values are being used to mean "no value".',
                'examples', json_array('N/A', 'unknown', '-1 where a real count is expected', '9999-12-31', 'the empty string', '0 used to mean "not recorded"')),
            'false', 'Every value is a genuine observation; absence is expressed as NULL.')),

    'encoded_code', q_noul(
        'Are these values a compact code whose meaning a reader could not work out from `column.name` alone?',
        json_object(
            'true',  json_object(
                'what',     'Short codes standing for something the name does not spell out.',
                'examples', json_array('a column `st` holding A, C and P for order status', 'numeric type codes such as 1, 2, 3')),
            'false', 'The values are self-explanatory, or the name already says what the code means.')),

    'unit', q_choice(
        'If these values are a measurement or an amount, what unit or currency are they expressed in? Answer `not_a_measurement` if they are not a quantity at all, and `unstated` if they are but no unit can be determined.',
        json_object(
            'not_a_measurement', 'These values are not a measurement or monetary amount.',
            'unstated',          'They are a quantity, but nothing in the data says what unit or currency.',
            'mixed',             'More than one unit or currency appears within these values.',
            'stated_in_values',  'Each value carries its own unit, e.g. `12 kg`.',
            'stated_in_name',    'The column name gives the unit, e.g. `weight_kg` or `price_usd`.',
            'implied_by_siblings', 'A neighbouring column supplies the unit or currency, e.g. a `currency` column.'))
);

-- One row per column. `answers` keeps the raw judgments so you can re-slice
-- without paying for another call.
CREATE OR REPLACE MACRO profile_columns(tbl, n := 200) AS TABLE
    WITH cv AS (SELECT * FROM profile_column_values(tbl, n)),
    sib AS (SELECT to_json(list(column_name ORDER BY ordinal)) AS cols FROM profile_schema(tbl)),
    ctx AS (SELECT profile_context_rows(tbl, 3) AS example_rows),
    asked AS (
        SELECT cv.ordinal, cv.column_name, cv.declared_type, cv.sample_values, cv.distinct_values,
               ts_answers(
                   json_object(
                       'table',                     tbl,
                       'column',                    json_object('name', cv.column_name, 'declared_type', cv.declared_type),
                       'sibling_columns',           json(sib.cols),
                       'sample_values',             json(cv.sample_values),
                       'distinct_values_in_sample', cv.distinct_values,
                       'example_rows',              json(ctx.example_rows)),
                   profile_discovery_questions()) AS a
        FROM cv, sib, ctx
    )
    SELECT
        column_name,
        declared_type,
        choice_of(a, 'semantic_type').choice                       AS semantic_type,
        choice_of(a, 'semantic_type').confidence                   AS semantic_type_confidence,
        choice_of(a, 'role').choice                                AS role,
        noul_of(a, 'name_matches_values')                          AS name_matches_values,
        noul_of(a, 'sensitive')                                    AS sensitive_personal_data,
        score_of(a, 'format_consistency').score                    AS format_inconsistency,
        noul_of(a, 'sentinels')                                    AS has_sentinel_values,
        noul_of(a, 'encoded_code')                                 AS is_encoded_code,
        -- Asked speculatively for every column; only consumed where it means something.
        CASE WHEN choice_of(a, 'semantic_type').choice IN (
                'currency_amount', 'physical_measurement', 'percentage',
                'count_or_quantity', 'duration')
             THEN choice_of(a, 'unit').choice END                  AS unit_or_currency,
        distinct_values,
        sample_values,
        a                                                          AS answers
    FROM asked
    ORDER BY ordinal;
